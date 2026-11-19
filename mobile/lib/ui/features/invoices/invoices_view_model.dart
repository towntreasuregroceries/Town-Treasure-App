import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';
import 'invoice_formatters.dart';

enum SaveInvoiceOutcome {
  saved,
  validationError,
  duplicateDetected,
  duplicateCheckUnavailable,
}

class SaveInvoiceResult {
  const SaveInvoiceResult({
    required this.outcome,
    this.invoice,
    this.synced = false,
    this.message = '',
    this.matchedDuplicate,
    this.matchingItemsCount = 0,
  });

  final SaveInvoiceOutcome outcome;
  final Invoice? invoice;
  final bool synced;
  final String message;
  final Invoice? matchedDuplicate;
  final int matchingItemsCount;
}

class ActionOutcome {
  const ActionOutcome({
    required this.ok,
    required this.synced,
    required this.message,
  });

  final bool ok;
  final bool synced;
  final String message;
}

/// ViewModel for Invoices list, editor (with live margins + drafts + CSV),
/// detail status toggles, and Recycle Bin recovery (`invoices.js`, `payroll.js`, `pricelist.js`).
class InvoicesViewModel extends ChangeNotifier {
  InvoicesViewModel({
    required this._vault,
    this._autoSaveDebounce = const Duration(seconds: 1),
  }) {
    _vault.addListener(_onVaultChanged);
    resetEditor();
  }

  final VaultRepository _vault;
  final Duration _autoSaveDebounce;

  // --- List filters ---
  String _searchQuery = '';
  String _filterRestaurantId = '';
  String _filterMonth = '';
  String _filterStatus = '';

  String get searchQuery => _searchQuery;
  String get filterRestaurantId => _filterRestaurantId;
  String get filterMonth => _filterMonth;
  String get filterStatus => _filterStatus;

  /// Distinct `YYYY-MM` month keys across non-draft invoices, newest first.
  List<String> get availableMonths {
    final months = <String>{};
    for (final inv in _vault.invoices) {
      if (inv.isDraft) continue;
      final key = InvoiceFormatters.monthKeyFromDate(inv.date);
      if (key.isNotEmpty) months.add(key);
    }
    final sorted = months.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  // --- Editor state ---
  String? _editingInvoiceId;
  String _restaurantId = '';
  String _date = InvoiceFormatters.todayIso();
  String _dueDate = '';
  String _notes = '';
  double _deliveryCost = 0;
  double _otherCost = 0;
  List<InvoiceLineItem> _items = [
    const InvoiceLineItem(
      desc: '',
      qty: 1,
      unit: 'kgs',
      buyPrice: 0,
      sellPrice: 0,
      total: 0,
    ),
  ];
  Timer? _autoSaveTimer;
  bool _isSaving = false;

  String? get editingInvoiceId => _editingInvoiceId;
  String get restaurantId => _restaurantId;
  String get date => _date;
  String get dueDate => _dueDate;
  String get notes => _notes;
  double get deliveryCost => _deliveryCost;
  double get otherCost => _otherCost;
  List<InvoiceLineItem> get items => List.unmodifiable(_items);
  bool get isSaving => _isSaving;

  double get totalSell =>
      _items.fold(0.0, (sum, item) => sum + (item.qty * item.sellPrice));
  double get totalBuy =>
      _items.fold(0.0, (sum, item) => sum + (item.qty * item.buyPrice));
  double get opsCost => _deliveryCost + _otherCost;
  double get profit => totalSell - totalBuy - _deliveryCost - _otherCost;
  double get marginPercent => totalSell > 0 ? (profit / totalSell) * 100 : 0.0;

  // --- Vault derived collections ---

  List<Restaurant> get restaurants => _vault.restaurants;

  List<Invoice> get drafts =>
      _vault.invoices.where((inv) => inv.isDraft).toList().reversed.toList();

  List<Invoice> get filteredInvoices {
    final rests = _vault.restaurants;
    var list = _vault.invoices.where((inv) => !inv.isDraft).toList();
    list.sort((a, b) {
      final dateCmp =
          AppHelpers.appDateKey(b.date).compareTo(AppHelpers.appDateKey(a.date));
      if (dateCmp != 0) return dateCmp;
      return (b.createdAt ?? '').compareTo(a.createdAt ?? '');
    });

    final q = _searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((inv) {
        final displayName =
            Restaurant.invoiceDisplayName(inv, rests).toLowerCase();
        final monthKey = InvoiceFormatters.monthKeyFromDate(inv.date);
        final monthLabel =
            InvoiceFormatters.formatMonthLabel(monthKey).toLowerCase();
        return inv.number.toLowerCase().contains(q) ||
            displayName.contains(q) ||
            inv.restaurantName.toLowerCase().contains(q) ||
            inv.date.toLowerCase().contains(q) ||
            InvoiceFormatters.formatDisplayDate(inv.date).toLowerCase().contains(q) ||
            monthLabel.contains(q);
      }).toList();
    }

    if (_filterRestaurantId.isNotEmpty) {
      final selectedIdx =
          rests.indexWhere((r) => r.id == _filterRestaurantId);
      if (selectedIdx < 0) return const [];
      final selected = rests[selectedIdx];
      list = list
          .where((inv) =>
              Restaurant.invoiceBelongsToRestaurant(inv, selected, rests))
          .toList();
    }

    if (_filterMonth.isNotEmpty) {
      list = list
          .where(
            (inv) => InvoiceFormatters.monthKeyFromDate(inv.date) == _filterMonth,
          )
          .toList();
    }

    if (_filterStatus.isNotEmpty) {
      list = list.where((inv) => inv.status == _filterStatus).toList();
    }

    return list;
  }

  List<Invoice> get deletedInvoices => _vault.deletedInvoices.reversed.toList();
  List<Staff> get deletedStaff => _vault.deletedStaff.reversed.toList();
  List<PriceList> get deletedPriceLists =>
      _vault.deletedPriceLists.reversed.toList();

  Invoice? findInvoiceById(String id) {
    final idx = _vault.invoices.indexWhere((inv) => inv.id == id);
    return idx >= 0 ? _vault.invoices[idx] : null;
  }

  Restaurant? resolveRestaurant(Invoice invoice) {
    final res =
        Restaurant.resolveInvoiceRestaurant(invoice, _vault.restaurants);
    return res.restaurant;
  }

  String displayRestaurantName(Invoice invoice) {
    return Restaurant.invoiceDisplayName(invoice, _vault.restaurants);
  }

  String generateSecureInvoiceNumber() {
    return _vault.generateSecureInvoiceNumber();
  }

  // --- Filter Mutators ---

  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    notifyListeners();
  }

  void setFilterRestaurantId(String restaurantId) {
    if (_filterRestaurantId == restaurantId) return;
    _filterRestaurantId = restaurantId;
    notifyListeners();
  }

  void setFilterMonth(String month) {
    if (_filterMonth == month) return;
    _filterMonth = month;
    notifyListeners();
  }

  void setFilterStatus(String status) {
    if (_filterStatus == status) return;
    _filterStatus = status;
    notifyListeners();
  }

  // --- Editor Mutators ---

  void resetEditor({
    String? prefillRestaurantId,
    String? prefillDate,
    List<InvoiceLineItem>? prefillItems,
  }) {
    _autoSaveTimer?.cancel();
    _editingInvoiceId = null;
    _restaurantId = prefillRestaurantId ?? '';
    _date = (prefillDate != null && prefillDate.trim().isNotEmpty)
        ? AppHelpers.normalizeAppDate(prefillDate)
        : InvoiceFormatters.todayIso();
    if (_date.isEmpty) _date = InvoiceFormatters.todayIso();
    _dueDate = '';
    _notes = '';
    _deliveryCost = 0;
    _otherCost = 0;
    if (prefillItems != null && prefillItems.isNotEmpty) {
      _items = prefillItems.map(_recomputeItem).toList();
    } else {
      _items = [
        const InvoiceLineItem(
          desc: '',
          qty: 1,
          unit: 'kgs',
          buyPrice: 0,
          sellPrice: 0,
          total: 0,
        ),
      ];
    }
    notifyListeners();
  }

  void loadInvoiceForEdit(Invoice invoice) {
    _autoSaveTimer?.cancel();
    _editingInvoiceId = invoice.id;
    _restaurantId = invoice.restaurantId;
    final normDate = AppHelpers.normalizeAppDate(invoice.date);
    _date = normDate.isNotEmpty ? normDate : InvoiceFormatters.todayIso();
    _dueDate = invoice.dueDate;
    _notes = invoice.notes;
    _deliveryCost = invoice.deliveryCost;
    _otherCost = invoice.otherCost;
    _items = invoice.items.isNotEmpty
        ? invoice.items.map(_recomputeItem).toList()
        : [
            const InvoiceLineItem(
              desc: '',
              qty: 1,
              unit: 'kgs',
              buyPrice: 0,
              sellPrice: 0,
              total: 0,
            ),
          ];
    notifyListeners();
  }

  void setEditorRestaurantId(String value, {bool triggerAutoSave = true}) {
    _restaurantId = value;
    notifyListeners();
    if (triggerAutoSave) scheduleAutoSave();
  }

  void setEditorDate(String value, {bool triggerAutoSave = true}) {
    final norm = AppHelpers.normalizeAppDate(value);
    _date = norm.isNotEmpty ? norm : value;
    notifyListeners();
    if (triggerAutoSave) scheduleAutoSave();
  }

  void setEditorDueDate(String value, {bool triggerAutoSave = true}) {
    _dueDate = value;
    notifyListeners();
    if (triggerAutoSave) scheduleAutoSave();
  }

  void setEditorNotes(String value, {bool triggerAutoSave = true}) {
    _notes = value;
    notifyListeners();
    if (triggerAutoSave) scheduleAutoSave();
  }

  void setEditorDeliveryCost(double value, {bool triggerAutoSave = true}) {
    _deliveryCost = value;
    notifyListeners();
    if (triggerAutoSave) scheduleAutoSave();
  }

  void setEditorOtherCost(double value, {bool triggerAutoSave = true}) {
    _otherCost = value;
    notifyListeners();
    if (triggerAutoSave) scheduleAutoSave();
  }

  void addLineItem([InvoiceLineItem? item]) {
    _items = [
      ..._items,
      item != null
          ? _recomputeItem(item)
          : const InvoiceLineItem(
              desc: '',
              qty: 1,
              unit: 'kgs',
              buyPrice: 0,
              sellPrice: 0,
              total: 0,
            ),
    ];
    notifyListeners();
  }

  void updateLineItem(
    int index, {
    String? desc,
    double? qty,
    String? unit,
    double? buyPrice,
    double? sellPrice,
    bool triggerAutoSave = true,
  }) {
    if (index < 0 || index >= _items.length) return;
    final current = _items[index];
    final nextQty = qty ?? current.qty;
    final nextSell = sellPrice ?? current.sellPrice;
    final updated = current.copyWith(
      desc: desc,
      qty: nextQty,
      unit: unit != null ? InvoiceFormatters.normalizeUnit(unit) : null,
      buyPrice: buyPrice,
      sellPrice: nextSell,
      total: nextQty * nextSell,
    );
    final copy = List<InvoiceLineItem>.from(_items);
    copy[index] = updated;
    _items = copy;
    notifyListeners();
    if (triggerAutoSave) scheduleAutoSave();
  }

  void removeLineItem(int index) {
    if (_items.length <= 1 || index < 0 || index >= _items.length) return;
    final copy = List<InvoiceLineItem>.from(_items)..removeAt(index);
    _items = copy;
    notifyListeners();
    scheduleAutoSave();
  }

  void applyImportedItems(
    List<InvoiceLineItem> imported, {
    bool replace = true,
  }) {
    if (imported.isEmpty) return;
    final normalized = imported.map(_recomputeItem).toList();
    if (replace) {
      _items = normalized;
    } else {
      final nonEmpty =
          _items.where((i) => i.desc.trim().isNotEmpty || i.sellPrice > 0);
      _items = [...nonEmpty, ...normalized];
    }
    notifyListeners();
    scheduleAutoSave();
  }

  String exportEditorItemsCsv() {
    final valid = _items.where((i) => i.desc.trim().isNotEmpty).toList();
    return InvoiceFormatters.itemsToCsv(valid);
  }

  int importCsvText(String csvText, {bool replace = true}) {
    final parsed = InvoiceFormatters.csvToItems(csvText);
    if (parsed.isEmpty) return 0;
    applyImportedItems(parsed, replace: replace);
    return parsed.length;
  }

  InvoiceLineItem _recomputeItem(InvoiceLineItem item) {
    return item.copyWith(
      unit: InvoiceFormatters.normalizeUnit(item.unit),
      total: item.qty * item.sellPrice,
    );
  }

  // --- Drafts & Auto-save (`invoices.js:281-467`) ---

  void scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_autoSaveDebounce, () {
      final existing = _editingInvoiceId != null
          ? findInvoiceById(_editingInvoiceId!)
          : null;
      // Never demote an existing non-draft invoice to a draft on auto-save.
      if (existing != null && !existing.isDraft) return;
      final hasMeaningfulItems = _items.any(
        (i) => i.desc.trim().isNotEmpty || i.buyPrice > 0 || i.sellPrice > 0,
      );
      if (_restaurantId.isNotEmpty || hasMeaningfulItems) {
        saveDraft(silent: true);
      }
    });
  }

  Future<ActionOutcome> saveDraft({bool silent = false}) async {
    final existing = _editingInvoiceId != null
        ? findInvoiceById(_editingInvoiceId!)
        : null;
    if (existing != null && !existing.isDraft) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'This is an existing invoice. Use Save Invoice to update it.',
      );
    }

    if (!silent) {
      _autoSaveTimer?.cancel();
    }

    final draftItems = _items
        .where(
          (i) =>
              i.desc.trim().isNotEmpty ||
              i.qty > 0 ||
              i.buyPrice > 0 ||
              i.sellPrice > 0,
        )
        .map((i) => _recomputeItem(i.copyWith(desc: i.desc.trim())))
        .toList();

    final dTotalSell =
        draftItems.fold(0.0, (s, i) => s + (i.qty * i.sellPrice));
    final dTotalBuy = draftItems.fold(0.0, (s, i) => s + (i.qty * i.buyPrice));
    final restIdx =
        _vault.restaurants.indexWhere((r) => r.id == _restaurantId);
    final rest = restIdx >= 0 ? _vault.restaurants[restIdx] : null;
    final now = DateTime.now().toUtc().toIso8601String();
    final invId = _editingInvoiceId ?? AppHelpers.genId();
    final invNumber = existing?.number ?? '${generateSecureInvoiceNumber()}-D';
    final createdAt = existing?.createdAt ?? now;
    final invDateVal =
        _date.trim().isNotEmpty ? _date.trim() : InvoiceFormatters.todayIso();

    final draft = Invoice(
      id: invId,
      number: invNumber,
      restaurantId: _restaurantId,
      restaurantName: rest?.name ?? 'Unknown',
      date: invDateVal,
      dueDate: _dueDate,
      items: draftItems,
      totalSell: dTotalSell,
      totalBuy: dTotalBuy,
      deliveryCost: _deliveryCost,
      otherCost: _otherCost,
      profit: dTotalSell - dTotalBuy - _deliveryCost - _otherCost,
      notes: _notes.trim(),
      status: 'draft',
      createdAt: createdAt,
      updatedAt: now,
    );

    final list = List<Invoice>.from(_vault.invoices);
    final idx = list.indexWhere((i) => i.id == invId);
    if (idx >= 0) {
      list[idx] = draft;
    } else {
      list.add(draft);
    }
    _editingInvoiceId = invId;
    await _vault.setInvoices(list, sync: false);

    if (silent) {
      notifyListeners();
      return const ActionOutcome(
        ok: true,
        synced: false,
        message: 'Draft auto-saved',
      );
    }

    final synced = await _boundedSync();
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: synced
          ? 'The invoice draft was saved and synced to the account.'
          : 'The draft is saved on this device, but cloud sync was not confirmed.',
    );
  }

  Future<bool> _boundedSync() {
    return _vault.syncNow().timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        _vault.scheduleSync();
        return false;
      },
    );
  }

  Future<ActionOutcome> deleteDraft(String id) async {
    _autoSaveTimer?.cancel();
    final draft = findInvoiceById(id);
    if (draft != null) {
      final now = DateTime.now().toUtc().toIso8601String();
      final bin = _vault.deletedInvoices.where((i) => i.id != id).toList()
        ..add(
          draft.copyWith(
            deletedAt: now,
            originalStatus: 'draft',
          ),
        );
      await _vault.setDeletedInvoices(bin, sync: false);
      await _vault.setDeletedInvoiceIds(
        <String>{..._vault.deletedInvoiceIds, id}.toList(),
        sync: false,
      );
      await _vault.setRestoredInvoiceIds(
        _vault.restoredInvoiceIds.where((r) => r != id).toList(),
        sync: false,
      );
      await _vault.markRecordDeleted('invoices', id, sync: false);
    }

    await _vault.setInvoices(
      _vault.invoices.where((i) => i.id != id).toList(),
      sync: false,
    );
    if (_editingInvoiceId == id) {
      resetEditor();
    }
    final synced = await _boundedSync();
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: synced
          ? 'The draft was deleted and synced to your account.'
          : 'The draft was removed on this device, but cloud sync was not confirmed.',
    );
  }

  // --- Save Invoice (`invoices.js:52-266`) ---

  Future<SaveInvoiceResult> saveInvoice({
    bool bypassDuplicateCheck = false,
  }) async {
    if (_isSaving) {
      return const SaveInvoiceResult(
        outcome: SaveInvoiceOutcome.validationError,
        message: 'Save is already in progress. Please wait...',
      );
    }
    if (_restaurantId.isEmpty) {
      return const SaveInvoiceResult(
        outcome: SaveInvoiceOutcome.validationError,
        message: 'Select a restaurant.',
      );
    }

    final cleanedItems = <InvoiceLineItem>[];
    for (final row in _items) {
      final desc = row.desc.trim();
      if (desc.isEmpty) {
        return const SaveInvoiceResult(
          outcome: SaveInvoiceOutcome.validationError,
          message: 'Fill in all item descriptions.',
        );
      }
      if (!row.qty.isFinite || row.qty <= 0) {
        return const SaveInvoiceResult(
          outcome: SaveInvoiceOutcome.validationError,
          message: 'Item quantities must be greater than zero.',
        );
      }
      if (!row.buyPrice.isFinite ||
          row.buyPrice < 0 ||
          !row.sellPrice.isFinite ||
          row.sellPrice < 0) {
        return const SaveInvoiceResult(
          outcome: SaveInvoiceOutcome.validationError,
          message: 'Item prices cannot be negative.',
        );
      }
      cleanedItems.add(
        InvoiceLineItem(
          desc: desc,
          qty: row.qty,
          unit: InvoiceFormatters.normalizeUnit(row.unit),
          buyPrice: row.buyPrice,
          sellPrice: row.sellPrice,
          total: row.qty * row.sellPrice,
        ),
      );
    }
    if (cleanedItems.isEmpty) {
      return const SaveInvoiceResult(
        outcome: SaveInvoiceOutcome.validationError,
        message: 'Add at least one line item.',
      );
    }
    if (_deliveryCost < 0 || _otherCost < 0) {
      return const SaveInvoiceResult(
        outcome: SaveInvoiceOutcome.validationError,
        message: 'Delivery and other costs cannot be negative.',
      );
    }

    final restIdx =
        _vault.restaurants.indexWhere((r) => r.id == _restaurantId);
    if (restIdx < 0) {
      return const SaveInvoiceResult(
        outcome: SaveInvoiceOutcome.validationError,
        message:
            'That restaurant record is unavailable. Refresh the restaurant list before saving.',
      );
    }
    final rest = _vault.restaurants[restIdx];

    final calcSell = cleanedItems.fold(0.0, (s, i) => s + i.total);
    final calcBuy =
        cleanedItems.fold(0.0, (s, i) => s + (i.qty * i.buyPrice));
    final invDateVal =
        _date.trim().isNotEmpty ? _date.trim() : InvoiceFormatters.todayIso();
    final existingRecord = _editingInvoiceId != null
        ? findInvoiceById(_editingInvoiceId!)
        : null;

    _isSaving = true;
    notifyListeners();
    try {
      // Smart Audit Ledger Collision Guard
      if ((_editingInvoiceId == null || (existingRecord?.isDraft ?? false)) &&
          !bypassDuplicateCheck) {
        final snapshot = await _vault
            .getRemoteInvoiceSnapshot()
            .timeout(
              const Duration(seconds: 6),
              onTimeout: () => const RemoteInvoiceSnapshot(ok: false),
            );
        if (!snapshot.ok) {
          return const SaveInvoiceResult(
            outcome: SaveInvoiceOutcome.duplicateCheckUnavailable,
            message:
                'The current server invoice list could not be verified, so the duplicate check is unavailable. Saving now may create a repeat invoice if this delivery was already entered on another device.',
          );
        }

        Invoice? matched;
        DuplicateScore? bestScore;
        for (final ex in snapshot.invoices) {
          if (ex.id == _editingInvoiceId) continue;
          if (!Restaurant.invoiceBelongsToRestaurant(
            ex,
            rest,
            _vault.restaurants,
          )) {
            continue;
          }
          final score = InvoiceDuplicateGuard.calculateHeuristicScore(
            candidateRestaurantName: rest.name,
            candidateDate: invDateVal,
            candidateTotalSell: calcSell,
            candidateItems: cleanedItems,
            existing: ex,
          );
          if (bestScore == null || score.score > bestScore.score) {
            bestScore = score;
            matched = ex;
          }
        }

        if (matched != null &&
            bestScore != null &&
            InvoiceDuplicateGuard.isHighConfidenceDuplicate(bestScore)) {
          return SaveInvoiceResult(
            outcome: SaveInvoiceOutcome.duplicateDetected,
            matchedDuplicate: matched,
            matchingItemsCount: bestScore.matchingItemsCount,
            message:
                'Possible duplicate: Invoice #${matched.number} for ${rest.name} on ${matched.date} looks very similar.',
          );
        }
      }

      _autoSaveTimer?.cancel();
      final now = DateTime.now().toUtc().toIso8601String();
      final invId = _editingInvoiceId ?? AppHelpers.genId();
      final String invNumber;
      final String createdAt;

      if (existingRecord != null) {
        createdAt = existingRecord.createdAt ?? now;
        final isDraftNumber =
            RegExp(r'-D$', caseSensitive: false).hasMatch(existingRecord.number);
        invNumber = (existingRecord.isDraft || isDraftNumber)
            ? generateSecureInvoiceNumber()
            : existingRecord.number;
      } else {
        createdAt = now;
        invNumber = generateSecureInvoiceNumber();
      }

      final nextStatus =
          (existingRecord != null && !existingRecord.isDraft)
              ? existingRecord.status
              : 'pending';

      final saved = Invoice(
        id: invId,
        sourceSubmissionId: existingRecord?.sourceSubmissionId,
        number: invNumber,
        restaurantId: rest.id,
        restaurantName: rest.name,
        date: invDateVal,
        dueDate: _dueDate.trim(),
        items: cleanedItems,
        totalSell: calcSell,
        totalBuy: calcBuy,
        deliveryCost: _deliveryCost,
        otherCost: _otherCost,
        profit: calcSell - calcBuy - _deliveryCost - _otherCost,
        notes: _notes.trim(),
        status: nextStatus,
        paidDate: existingRecord?.paidDate,
        createdAt: createdAt,
        updatedAt: now,
      );

      final nextInvoices = List<Invoice>.from(_vault.invoices);
      final idx = nextInvoices.indexWhere((i) => i.id == invId);
      if (idx >= 0) {
        nextInvoices[idx] = saved;
      } else {
        nextInvoices.add(saved);
      }
      await _vault.setInvoices(nextInvoices, sync: false);

      // Replace linked operational expenses
      final replaced =
          _vault.expenses.where((e) => e.invId == invId).toList();
      for (final exp in replaced) {
        await _vault.markRecordDeleted('expenses', exp.id, sync: false);
      }
      final nextExpenses =
          _vault.expenses.where((e) => e.invId != invId).toList();
      if (_deliveryCost > 0) {
        nextExpenses.add(
          Expense(
            id: AppHelpers.genId(),
            invId: invId,
            type: 'expense',
            date: invDateVal,
            desc: 'Delivery: ${saved.number} (${saved.restaurantName})',
            category: 'transport',
            amount: _deliveryCost,
          ),
        );
      }
      if (_otherCost > 0) {
        nextExpenses.add(
          Expense(
            id: AppHelpers.genId(),
            invId: invId,
            type: 'expense',
            date: invDateVal,
            desc: 'Ops Cost: ${saved.number} (${saved.restaurantName})',
            category: 'other',
            amount: _otherCost,
          ),
        );
      }
      await _vault.setExpenses(nextExpenses, sync: false);

      final synced = await _boundedSync();
      resetEditor();
      return SaveInvoiceResult(
        outcome: SaveInvoiceOutcome.saved,
        invoice: saved,
        synced: synced,
        message: synced
            ? 'Invoice ${saved.number} was saved and synced to the account.'
            : 'Invoice ${saved.number} is saved on this device, but cloud sync was not confirmed.',
      );
    } finally {
      _isSaving = false;
      notifyListeners();
    }
  }

  // --- Paid / Unpaid & Soft Delete (`invoices.js:496-520`, `680-732`) ---

  Future<ActionOutcome> markAsPaid(String id) async {
    final idx = _vault.invoices.indexWhere((i) => i.id == id);
    if (idx < 0) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'Invoice not found.',
      );
    }
    final list = List<Invoice>.from(_vault.invoices);
    final inv = list[idx];
    final updated = inv.copyWith(
      status: 'paid',
      paidDate: InvoiceFormatters.todayIso(),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    list[idx] = updated;
    await _vault.setInvoices(list, sync: false);
    final synced = await _boundedSync();
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: 'Invoice ${updated.number} marked as paid',
    );
  }

  /// Marks multiple unpaid non-draft invoices as paid in a single atomic vault update.
  Future<ActionOutcome> markInvoicesAsPaid(List<String> ids) async {
    if (ids.isEmpty) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'No invoices selected.',
      );
    }
    final targetIds = ids.toSet();
    final today = InvoiceFormatters.todayIso();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final list = List<Invoice>.from(_vault.invoices);
    var updatedCount = 0;

    for (var i = 0; i < list.length; i++) {
      final inv = list[i];
      if (targetIds.contains(inv.id) && !inv.isDraft && inv.status != 'paid') {
        list[i] = inv.copyWith(
          status: 'paid',
          paidDate: today,
          updatedAt: nowIso,
        );
        updatedCount++;
      }
    }

    if (updatedCount == 0) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'Selected invoices are already marked as paid.',
      );
    }

    await _vault.setInvoices(list, sync: false);
    final synced = await _boundedSync();
    final noun = updatedCount == 1 ? 'invoice' : 'invoices';
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: synced
          ? '$updatedCount $noun marked as paid and synced.'
          : '$updatedCount $noun marked as paid on this device (cloud sync pending).',
    );
  }

  Future<ActionOutcome> markAsUnpaid(String id) async {
    final idx = _vault.invoices.indexWhere((i) => i.id == id);
    if (idx < 0) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'Invoice not found.',
      );
    }
    final list = List<Invoice>.from(_vault.invoices);
    final inv = list[idx];
    final updated = inv.copyWith(
      status: 'pending',
      clearPaidDate: true,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    list[idx] = updated;
    await _vault.setInvoices(list, sync: false);
    final synced = await _boundedSync();
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: 'Invoice ${updated.number} marked as unpaid (pending)',
    );
  }

  Future<ActionOutcome> softDeleteInvoice(String id) async {
    _autoSaveTimer?.cancel();
    final inv = findInvoiceById(id);
    if (inv != null) {
      final now = DateTime.now().toUtc().toIso8601String();
      final deleted = inv.copyWith(
        deletedAt: now,
        originalStatus: inv.status,
      );
      final bin = List<Invoice>.from(_vault.deletedInvoices)..add(deleted);
      await _vault.setDeletedInvoices(bin, sync: false);
      await _vault.setDeletedInvoiceIds(
        <String>{..._vault.deletedInvoiceIds, id}.toList(),
        sync: false,
      );
      await _vault.setRestoredInvoiceIds(
        _vault.restoredInvoiceIds.where((r) => r != id).toList(),
        sync: false,
      );
      await _vault.markRecordDeleted('invoices', id, sync: false);
    }

    await _vault.setInvoices(
      _vault.invoices.where((i) => i.id != id).toList(),
      sync: false,
    );

    final linkedExpenses =
        _vault.expenses.where((e) => e.invId == id).toList();
    for (final exp in linkedExpenses) {
      await _vault.markRecordDeleted('expenses', exp.id, sync: false);
    }
    if (linkedExpenses.isNotEmpty) {
      await _vault.setExpenses(
        _vault.expenses.where((e) => e.invId != id).toList(),
        sync: false,
      );
    }

    if (_editingInvoiceId == id) {
      resetEditor();
    }

    final synced = await _boundedSync();
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: synced
          ? 'The invoice was moved to the Recycle Bin and synced to your account.'
          : 'The invoice is in this device Recycle Bin, but cloud sync was not confirmed.',
    );
  }

  // --- Recycle Bin Recovery (`invoices.js:594-662`, `payroll.js:78-92`, `pricelist.js:746-760`) ---

  Future<ActionOutcome> restoreInvoices(List<String> ids) async {
    if (ids.isEmpty) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'No items selected.',
      );
    }
    final idSet = ids.toSet();
    final bin = _vault.deletedInvoices;
    final list = List<Invoice>.from(_vault.invoices);
    var expList = List<Expense>.from(_vault.expenses);
    final restoredIds = <String>[];
    final now = DateTime.now().toUtc().toIso8601String();

    for (final inv in bin) {
      if (!idSet.contains(inv.id)) continue;
      final restoredStatus = (inv.originalStatus != null &&
              inv.originalStatus!.trim().isNotEmpty)
          ? inv.originalStatus!
          : (inv.status.trim().isNotEmpty ? inv.status : 'pending');
      final restored = inv.copyWith(
        status: restoredStatus,
        clearDeletedAt: true,
        clearOriginalStatus: true,
        updatedAt: now,
      );
      list.add(restored);
      restoredIds.add(inv.id);

      expList = expList.where((e) => e.invId != inv.id).toList();
      if (restored.deliveryCost > 0) {
        expList.add(
          Expense(
            id: AppHelpers.genId(),
            invId: inv.id,
            type: 'expense',
            date: restored.date,
            desc: 'Delivery: ${restored.number} (${restored.restaurantName})',
            category: 'transport',
            amount: restored.deliveryCost,
          ),
        );
      }
      if (restored.otherCost > 0) {
        expList.add(
          Expense(
            id: AppHelpers.genId(),
            invId: inv.id,
            type: 'expense',
            date: restored.date,
            desc: 'Ops Cost: ${restored.number} (${restored.restaurantName})',
            category: 'other',
            amount: restored.otherCost,
          ),
        );
      }
    }

    if (restoredIds.isEmpty) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'Invoice not found in bin.',
      );
    }

    final restoredSet = restoredIds.toSet();
    await _vault.setInvoices(list, sync: false);
    await _vault.setDeletedInvoices(
      bin.where((i) => !restoredSet.contains(i.id)).toList(),
      sync: false,
    );
    await _vault.setExpenses(expList, sync: false);
    await _vault.setDeletedInvoiceIds(
      _vault.deletedInvoiceIds
          .where((id) => !restoredSet.contains(id))
          .toList(),
      sync: false,
    );
    await _vault.setRestoredInvoiceIds(
      <String>{..._vault.restoredInvoiceIds, ...restoredIds}.toList(),
      sync: false,
    );
    for (final id in restoredIds) {
      await _vault.markRecordRestored('invoices', id, sync: false);
    }

    final synced = await _vault.syncNow();
    final label = restoredIds.length == 1
        ? 'Invoice restored'
        : '${restoredIds.length} invoice(s) restored';
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: synced
          ? '$label and synced.'
          : '$label on this device, but cloud sync was not confirmed.',
    );
  }

  Future<ActionOutcome> restoreStaffMembers(List<String> ids) async {
    if (ids.isEmpty) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'No items selected.',
      );
    }
    final idSet = ids.toSet();
    final bin = _vault.deletedStaff;
    final list = List<Staff>.from(_vault.staff);
    final restoredIds = <String>[];

    for (final s in bin) {
      if (!idSet.contains(s.id)) continue;
      list.add(s.copyWith(clearDeletedAt: true));
      restoredIds.add(s.id);
    }
    if (restoredIds.isEmpty) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'Staff member not found in bin.',
      );
    }

    final restoredSet = restoredIds.toSet();
    await _vault.setStaff(list, sync: false);
    await _vault.setDeletedStaff(
      bin.where((s) => !restoredSet.contains(s.id)).toList(),
      sync: false,
    );
    for (final id in restoredIds) {
      await _vault.markRecordRestored('staff', id, sync: false);
    }

    final synced = await _vault.syncNow();
    final label = restoredIds.length == 1
        ? 'Staff member restored'
        : '${restoredIds.length} staff member(s) restored';
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: synced
          ? '$label and synced.'
          : '$label on this device, but cloud sync was not confirmed.',
    );
  }

  Future<ActionOutcome> restorePriceLists(List<String> ids) async {
    if (ids.isEmpty) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'No items selected.',
      );
    }
    final idSet = ids.toSet();
    final bin = _vault.deletedPriceLists;
    final list = List<PriceList>.from(_vault.priceLists);
    final restoredIds = <String>[];

    for (final pl in bin) {
      if (!idSet.contains(pl.id)) continue;
      list.add(pl.copyWith(clearDeletedAt: true));
      restoredIds.add(pl.id);
    }
    if (restoredIds.isEmpty) {
      return const ActionOutcome(
        ok: false,
        synced: false,
        message: 'Price list not found in bin.',
      );
    }

    final restoredSet = restoredIds.toSet();
    await _vault.setPriceLists(list, sync: false);
    await _vault.setDeletedPriceLists(
      bin.where((p) => !restoredSet.contains(p.id)).toList(),
      sync: false,
    );
    for (final id in restoredIds) {
      await _vault.markRecordRestored('priceLists', id, sync: false);
    }

    final synced = await _vault.syncNow();
    final label = restoredIds.length == 1
        ? 'Price list restored'
        : '${restoredIds.length} price list(s) restored';
    return ActionOutcome(
      ok: true,
      synced: synced,
      message: synced
          ? '$label and synced.'
          : '$label on this device, but cloud sync was not confirmed.',
    );
  }

  void _onVaultChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _vault.removeListener(_onVaultChanged);
    super.dispose();
  }
}
