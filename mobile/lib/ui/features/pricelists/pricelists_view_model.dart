import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';

/// Duplicate commodity group detected inside a single price list.
class DuplicateCommodityGroup {
  const DuplicateCommodityGroup({
    required this.name,
    required this.normKey,
    required this.count,
    required this.itemIds,
  });

  final String name;
  final String normKey;
  final int count;
  final Set<String> itemIds;
}

/// Cross-catalog collision result against existing saved price lists.
class PriceListCollision {
  const PriceListCollision({
    required this.matched,
    required this.confidence,
    required this.isExactTitle,
    required this.matchingKeys,
    required this.overlapRatio,
    required this.totalRatio,
    required this.existingItemCount,
  });

  final PriceList matched;
  final double confidence;
  final bool isExactTitle;
  final List<String> matchingKeys;
  final double overlapRatio;
  final double totalRatio;
  final int existingItemCount;
}

/// Outcome of publishing/saving a price list with collision & duplicate checks.
class PublishPriceListResult {
  const PublishPriceListResult({
    this.saved,
    this.collision,
    this.internalDuplicates = const [],
    this.errorMessage,
  });

  final PriceList? saved;
  final PriceListCollision? collision;
  final List<DuplicateCommodityGroup> internalDuplicates;
  final String? errorMessage;

  bool get isSaved => saved != null;
  bool get hasWarning => collision != null || internalDuplicates.isNotEmpty;
}

/// Outcome of Smart Bulk Import from historical non-draft invoices.
class SmartImportResult {
  const SmartImportResult({
    this.newItems = const [],
    this.skippedCount = 0,
    this.totalCandidates = 0,
    this.message,
  });

  final List<PriceListItem> newItems;
  final int skippedCount;
  final int totalCandidates;
  final String? message;
}

/// Section grouping used by both preview and A4 PDF builder.
class PriceListSection {
  const PriceListSection({
    this.header,
    required this.items,
  });

  final String? header;
  final List<PriceListItem> items;
}

/// MVVM ViewModel for Price Lists matching `pricelist.js` and `duplicate-detector.js`.
class PriceListsViewModel extends ChangeNotifier {
  PriceListsViewModel({required this._vault}) {
    _vault.addListener(_onVaultChanged);
  }

  final VaultRepository _vault;
  Timer? _autoSaveTimer;

  static const List<String> categories = [
    'vegetables',
    'fruits',
    'cereals',
    'dairy',
    'meat',
    'fish',
    'legumes',
    'spices',
    'packaged',
    'other',
  ];

  static const List<String> units = [
    'kgs',
    'litres',
    'pieces',
    'crates',
    'bags',
    'trays',
    'bundles',
    'dozen',
    'packets',
    'bunch',
  ];

  static const Map<String, String> unitLabels = {
    'kgs': 'Kilogram',
    'litres': 'Litre',
    'pieces': 'Each',
    'crates': 'Crate',
    'bags': 'Bag',
    'trays': 'Tray',
    'bundles': 'Bundle',
    'dozen': 'Dozen',
    'packets': 'Packet',
    'banch': 'Bunch',
    'bunch': 'Bunch',
    'each': 'Each',
  };

  static const Map<String, String> produceAliases = {
    'roma tomatoes': 'tomatoes',
    'cooking tomatoes': 'tomatoes',
    'salad tomatoes': 'tomatoes',
    'local tomatoes': 'tomatoes',
    'fresh tomatoes': 'tomatoes',
    'potatoes (shangi)': 'potatoes',
    'shangi potatoes': 'potatoes',
    'irish potatoes': 'potatoes',
    'waru': 'potatoes',
    'warus': 'potatoes',
    'sweet capsicum': 'capsicum',
    'sweet capsicum (hoho)': 'capsicum',
    'hoho': 'capsicum',
    'green capsicum': 'capsicum',
    'red capsicum': 'capsicum',
    'yellow capsicum': 'capsicum',
    'bell pepper': 'capsicum',
    'green bell pepper': 'capsicum',
    'dhania': 'coriander',
    'dhania (coriander)': 'coriander',
    'cilantro': 'coriander',
    'sukuma wiki': 'sukuma wiki',
    'sukuma': 'sukuma wiki',
    'collard greens': 'sukuma wiki',
    'red onions (medium)': 'red onions',
    'red onions': 'red onions',
    'bombay onions': 'red onions',
    'bulb onions': 'red onions',
    'white onions': 'white onions',
    'baby spinach': 'spinach',
    'fresh spinach': 'spinach',
    'english cucumbers': 'cucumbers',
    'cucumbers': 'cucumbers',
    'button mushrooms': 'mushrooms',
    'fresh mushrooms': 'mushrooms',
    'garlic (imported)': 'garlic',
    'imported garlic': 'garlic',
    'local garlic': 'garlic',
    'fresh mint': 'mint',
    'mint leaves': 'mint',
    'courgettes': 'zucchini',
    'courgette': 'zucchini',
    'zucchini': 'zucchini',
    'managu': 'managu',
    'terere': 'terere',
    'kunde': 'kunde',
  };

  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  void _onVaultChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _vault.removeListener(_onVaultChanged);
    super.dispose();
  }

  List<PriceList> get priceLists => _vault.priceLists.reversed.toList();

  VaultSettings get settings => _vault.settings;

  PriceList? findById(String id) {
    for (final pl in _vault.priceLists) {
      if (pl.id == id) return pl;
    }
    return null;
  }

  static String formatMoney(double amount) => _moneyFormat.format(amount);

  static String formatDate(String? value) {
    if (value == null || value.trim().isEmpty) return '—';
    final parsed = AppHelpers.parseAppDate(value);
    if (parsed == null) return value;
    return DateFormat('dd/MM/yyyy').format(parsed);
  }

  static String formatMeasurement(String unit) {
    final lower = unit.toLowerCase().trim();
    if (lower == 'pieces') return 'Each';
    final mapped = unitLabels[lower];
    if (mapped != null) return mapped;
    if (unit.isEmpty) return 'Kilogram';
    return unit[0].toUpperCase() + unit.substring(1);
  }

  /// Normalizes produce description to canonical form matching `TTGAudit.canonicalProduce`.
  static String canonicalProduce(String desc) =>
      AppHelpers.canonicalProduce(desc);

  static String normalizeItemName(String desc) => canonicalProduce(desc);

  /// Category auto-guessing matching `guessPriceListCategory` in `pricelist.js`.
  static String guessCategory(String name) {
    final n = name.toLowerCase();
    const vegKeywords = [
      'tomato',
      'onion',
      'potato',
      'cabbage',
      'spinach',
      'carrot',
      'pepper',
      'lettuce',
      'cucumber',
      'broccoli',
      'kale',
      'sukuma',
      'dhania',
      'pilipili',
      'courgette',
      'managu',
      'terere',
    ];
    const fruitKeywords = [
      'banana',
      'orange',
      'apple',
      'mango',
      'avocado',
      'watermelon',
      'pineapple',
      'passion',
      'lemon',
      'lime',
      'pawpaw',
      'papaya',
      'grape',
    ];
    const cerealKeywords = [
      'rice',
      'maize',
      'wheat',
      'flour',
      'ugali',
      'bread',
      'chapati',
      'spaghetti',
      'pasta',
    ];
    const dairyKeywords = [
      'milk',
      'cheese',
      'yoghurt',
      'butter',
      'cream',
      'ghee',
    ];
    const meatKeywords = [
      'chicken',
      'beef',
      'goat',
      'pork',
      'mutton',
      'sausage',
      'bacon',
    ];
    const fishKeywords = [
      'fish',
      'tilapia',
      'nile',
      'sardine',
      'tuna',
      'omena',
    ];
    const spiceKeywords = [
      'salt',
      'sugar',
      'pepper',
      'ginger',
      'garlic',
      'turmeric',
      'cumin',
      'royco',
      'curry',
    ];

    if (vegKeywords.any(n.contains)) return 'vegetables';
    if (fruitKeywords.any(n.contains)) return 'fruits';
    if (cerealKeywords.any(n.contains)) return 'cereals';
    if (dairyKeywords.any(n.contains)) return 'dairy';
    if (meatKeywords.any(n.contains)) return 'meat';
    if (fishKeywords.any(n.contains)) return 'fish';
    if (spiceKeywords.any(n.contains)) return 'spices';
    return 'other';
  }

  /// Real-time duplicate produce commodity audit matching `auditPriceListDuplicates`.
  static List<DuplicateCommodityGroup> auditDuplicates(
    List<PriceListItem> items,
  ) {
    final counts = <String, List<PriceListItem>>{};
    for (final item in items) {
      if (item.isHeader) continue;
      final rawName = item.name.trim();
      if (rawName.isEmpty) continue;
      final normKey = normalizeItemName(rawName);
      if (normKey.isEmpty) continue;
      counts.putIfAbsent(normKey, () => []).add(item);
    }

    final duplicates = <DuplicateCommodityGroup>[];
    counts.forEach((normKey, occurrences) {
      if (occurrences.length > 1) {
        duplicates.add(
          DuplicateCommodityGroup(
            name: occurrences.first.name.trim(),
            normKey: normKey,
            count: occurrences.length,
            itemIds: occurrences.map((e) => e.id).toSet(),
          ),
        );
      }
    });
    return duplicates;
  }

  /// Catalog collision audit matching `checkPriceListCollisions` in `pricelist.js`.
  PriceListCollision? checkCollisions(
    String name,
    List<PriceListItem> items, {
    String? excludeId,
  }) {
    String normTitle(String str) => str
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');

    final targetTitle = normTitle(name);
    final validItems =
        items.where((i) => !i.isHeader && i.name.trim().isNotEmpty).toList();
    final targetProduceKeys = validItems
        .map((i) => canonicalProduce(i.name))
        .where((k) => k.isNotEmpty)
        .toSet();

    final candidates = _vault.priceLists
        .where((pl) => pl.id != excludeId && pl.deletedAt == null)
        .toList();
    if (candidates.isEmpty) return null;

    final collisions = <PriceListCollision>[];
    for (final pl in candidates) {
      final candTitle = normTitle(pl.name);
      final isExactTitle =
          targetTitle.isNotEmpty && candTitle.isNotEmpty && targetTitle == candTitle;

      final candItems = pl.items
          .where((i) => !i.isHeader && i.name.trim().isNotEmpty)
          .toList();
      final candProduceKeys = candItems
          .map((i) => canonicalProduce(i.name))
          .where((k) => k.isNotEmpty)
          .toSet();

      final matchingKeys = targetProduceKeys
          .where(candProduceKeys.contains)
          .toList();

      final minCount = min(targetProduceKeys.length, candProduceKeys.length);
      final maxCount = max(targetProduceKeys.length, candProduceKeys.length);

      final overlapRatio =
          minCount > 0 ? matchingKeys.length / minCount : 0.0;
      final totalRatio =
          maxCount > 0 ? matchingKeys.length / maxCount : 0.0;

      var confidence = 0.0;
      if (isExactTitle &&
          (totalRatio >= 0.70 ||
              (targetProduceKeys.isEmpty && candProduceKeys.isEmpty))) {
        confidence = 0.99;
      } else if (targetProduceKeys.length >= 3 && totalRatio >= 0.85) {
        confidence = 0.96;
      } else if (isExactTitle) {
        confidence = 0.90;
      } else if (targetProduceKeys.length >= 3 && overlapRatio >= 0.75) {
        confidence = 0.85;
      } else if (targetProduceKeys.isNotEmpty &&
          minCount <= 2 &&
          overlapRatio == 1.0) {
        confidence = 0.82;
      } else if (targetProduceKeys.length >= 4 && overlapRatio >= 0.65) {
        confidence = 0.75;
      }

      if (confidence >= 0.75) {
        collisions.add(
          PriceListCollision(
            matched: pl,
            confidence: confidence,
            isExactTitle: isExactTitle,
            matchingKeys: matchingKeys,
            overlapRatio: overlapRatio,
            totalRatio: totalRatio,
            existingItemCount: candItems.length,
          ),
        );
      }
    }

    if (collisions.isEmpty) return null;
    collisions.sort((a, b) {
      final cmp = b.confidence.compareTo(a.confidence);
      if (cmp != 0) return cmp;
      return b.overlapRatio.compareTo(a.overlapRatio);
    });
    return collisions.first;
  }

  /// Creates a new draft price list or resumes today's empty draft.
  Future<({PriceList priceList, bool resumed})> createOrResumeTodayDraft() async {
    final defaultName =
        'Price List — ${DateFormat('dd MMM yyyy').format(DateTime.now())}';
    for (final pl in _vault.priceLists) {
      final isEmptyFirst = pl.items.isEmpty || pl.items.first.name.trim().isEmpty;
      if (pl.status == 'draft' &&
          pl.name == defaultName &&
          pl.items.length <= 1 &&
          isEmptyFirst) {
        return (priceList: pl, resumed: true);
      }
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final created = PriceList(
      id: AppHelpers.genId(),
      name: defaultName,
      subtitle: 'Food Supplies (Veg and Fruits)',
      status: 'draft',
      items: [
        PriceListItem(
          id: AppHelpers.genId(),
          name: '',
          category: 'vegetables',
          unit: 'kgs',
          price: 0,
          notes: '',
        ),
      ],
      createdAt: nowIso,
      updatedAt: nowIso,
    );
    await _vault.setPriceLists([..._vault.priceLists, created]);
    return (priceList: created, resumed: false);
  }

  /// Schedules a 1-second debounced draft save matching `triggerPriceListAutoSave`.
  void scheduleAutoSave(PriceList draft) {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 1), () {
      saveDraft(draft);
    });
  }

  Future<void> saveDraft(PriceList draft) async {
    final list = List<PriceList>.from(_vault.priceLists);
    final idx = list.indexWhere((x) => x.id == draft.id);
    if (idx < 0) return;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    list[idx] = draft.copyWith(
      name: draft.name.trim().isEmpty ? list[idx].name : draft.name.trim(),
      subtitle: draft.subtitle.trim(),
      updatedAt: nowIso,
    );
    await _vault.setPriceLists(list);
  }

  /// Saves/publishes a price list with cross-catalog collision and internal duplicate checks.
  Future<PublishPriceListResult> publishPriceList(
    PriceList draft, {
    bool bypassDuplicateCheck = false,
  }) async {
    _autoSaveTimer?.cancel();
    final cleanedItems =
        draft.items.where((i) => i.name.trim().isNotEmpty).toList();
    if (cleanedItems.isEmpty) {
      return const PublishPriceListResult(
        errorMessage: 'Add at least one item with a name.',
      );
    }

    final list = List<PriceList>.from(_vault.priceLists);
    final idx = list.indexWhere((x) => x.id == draft.id);
    if (idx < 0) {
      return const PublishPriceListResult(
        errorMessage: 'Price list not found.',
      );
    }

    final resolvedName =
        draft.name.trim().isEmpty ? list[idx].name : draft.name.trim();

    if (!bypassDuplicateCheck) {
      final collision = checkCollisions(
        resolvedName,
        cleanedItems,
        excludeId: draft.id,
      );
      if (collision != null) {
        return PublishPriceListResult(collision: collision);
      }

      final internalDups = auditDuplicates(cleanedItems);
      if (internalDups.isNotEmpty) {
        return PublishPriceListResult(internalDuplicates: internalDups);
      }
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final saved = list[idx].copyWith(
      name: resolvedName,
      subtitle: draft.subtitle.trim(),
      status: draft.status.isEmpty ? 'active' : draft.status,
      items: cleanedItems,
      updatedAt: nowIso,
    );
    list[idx] = saved;
    await _vault.setPriceLists(list);
    return PublishPriceListResult(saved: saved);
  }

  /// Smart bulk import from non-draft invoices matching `smartImportItems` in `pricelist.js`.
  SmartImportResult smartImportFromInvoices(List<PriceListItem> currentItems) {
    final invoices =
        _vault.invoices.where((i) => !i.isDraft).toList()
          ..sort(
            (a, b) => AppHelpers.appDateKey(a.date)
                .compareTo(AppHelpers.appDateKey(b.date)),
          );
    if (invoices.isEmpty) {
      return const SmartImportResult(
        message: 'No invoices found to import from.',
      );
    }

    final itemMap = <String, PriceListItem>{};
    for (final inv in invoices) {
      for (final item in inv.items) {
        final key = item.desc.toLowerCase().trim();
        if (key.isEmpty) continue;
        itemMap[key] = PriceListItem(
          id: AppHelpers.genId(),
          name: item.desc.trim(),
          unit: item.unit.trim().isNotEmpty ? item.unit.trim() : 'kgs',
          price: item.sellPrice,
          category: guessCategory(item.desc),
          notes: '',
        );
      }
    }

    final importedItems = itemMap.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (importedItems.isEmpty) {
      return const SmartImportResult(
        message: 'No items found in invoices.',
      );
    }

    final existingNames = currentItems
        .where((i) => !i.isHeader && i.name.trim().isNotEmpty)
        .map((i) => normalizeItemName(i.name))
        .where((k) => k.isNotEmpty)
        .toSet();

    final newItems = importedItems
        .where((item) => !existingNames.contains(normalizeItemName(item.name)))
        .toList();

    final skippedCount = importedItems.length - newItems.length;
    if (newItems.isEmpty) {
      return SmartImportResult(
        newItems: const [],
        skippedCount: skippedCount,
        totalCandidates: importedItems.length,
        message: 'All produce items from past invoices are already in this price list.',
      );
    }

    return SmartImportResult(
      newItems: newItems,
      skippedCount: skippedCount,
      totalCandidates: importedItems.length,
      message: skippedCount > 0
          ? 'Imported ${newItems.length} items ($skippedCount duplicates skipped).'
          : 'Imported ${newItems.length} items.',
    );
  }

  /// Creates a new price list from scanned items (or returns collision if not bypassed).
  Future<PublishPriceListResult> createFromScannedItems(
    List<PriceListItem> scannedItems, {
    String? name,
    String? subtitle,
    bool bypassDuplicateCheck = false,
  }) async {
    final cleaned = scannedItems
        .where((i) => i.isHeader || i.name.trim().isNotEmpty)
        .map(
          (i) => i.id.isEmpty ? i.copyWith(id: AppHelpers.genId()) : i,
        )
        .toList();
    if (cleaned.isEmpty) {
      return const PublishPriceListResult(
        errorMessage: 'No extracted items to apply.',
      );
    }

    final plName = (name != null && name.trim().isNotEmpty)
        ? name.trim()
        : 'Price List — ${DateFormat('dd MMM yyyy').format(DateTime.now())}';

    if (!bypassDuplicateCheck) {
      final collision = checkCollisions(plName, cleaned);
      if (collision != null) {
        return PublishPriceListResult(collision: collision);
      }
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final created = PriceList(
      id: AppHelpers.genId(),
      name: plName,
      subtitle: (subtitle != null && subtitle.trim().isNotEmpty)
          ? subtitle.trim()
          : 'Food Supplies (Veg and Fruits)',
      status: 'draft',
      items: cleaned,
      createdAt: nowIso,
      updatedAt: nowIso,
    );
    await _vault.setPriceLists([..._vault.priceLists, created]);
    return PublishPriceListResult(saved: created);
  }

  Future<PriceList?> duplicatePriceList(String id) async {
    final original = findById(id);
    if (original == null) return null;
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final copy = PriceList(
      id: AppHelpers.genId(),
      name: '${original.name} (Copy)',
      subtitle: original.subtitle,
      status: 'draft',
      items: original.items
          .map((item) => item.copyWith(id: AppHelpers.genId()))
          .toList(),
      createdAt: nowIso,
      updatedAt: nowIso,
    );
    await _vault.setPriceLists([..._vault.priceLists, copy]);
    return copy;
  }

  Future<bool> softDeletePriceList(String id) async {
    final target = findById(id);
    if (target != null) {
      final deleted = target.copyWith(
        deletedAt: DateTime.now().toUtc().toIso8601String(),
      );
      await _vault.setDeletedPriceLists(
        [..._vault.deletedPriceLists, deleted],
        sync: false,
      );
    }
    await _vault.setPriceLists(
      _vault.priceLists.where((x) => x.id != id).toList(),
      sync: false,
    );
    await _vault.markRecordDeleted('priceLists', id, sync: false);
    return _boundedSync();
  }

  Future<bool> restorePriceList(String id) async {
    final bin = _vault.deletedPriceLists;
    final target = bin.where((x) => x.id == id).firstOrNull;
    if (target == null) return false;
    final restored = target.copyWith(clearDeletedAt: true);
    await _vault.setPriceLists([..._vault.priceLists, restored], sync: false);
    await _vault.setDeletedPriceLists(
      bin.where((x) => x.id != id).toList(),
      sync: false,
    );
    await _vault.markRecordRestored('priceLists', id, sync: false);
    return _boundedSync();
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

  /// Splits items by category header rows matching `buildPriceListPreview`.
  static List<PriceListSection> groupSections(PriceList pl) {
    final allItems = pl.items
        .where((i) => i.name.trim().isNotEmpty || i.isHeader)
        .toList();
    final sections = <PriceListSection>[];
    String? currentHeader;
    var currentItems = <PriceListItem>[];

    for (final item in allItems) {
      if (item.isHeader) {
        if (currentItems.isNotEmpty || currentHeader != null) {
          sections.add(
            PriceListSection(header: currentHeader, items: currentItems),
          );
        }
        currentHeader = item.name;
        currentItems = <PriceListItem>[];
      } else {
        currentItems.add(item);
      }
    }
    if (currentItems.isNotEmpty || currentHeader != null) {
      sections.add(
        PriceListSection(header: currentHeader, items: currentItems),
      );
    }
    return sections;
  }

  /// Builds WhatsApp share text matching `sharePriceListWhatsApp` in `pricelist.js`.
  static String buildWhatsAppShareText(PriceList pl) {
    final items = pl.items
        .where((i) => !i.isHeader && i.name.trim().isNotEmpty)
        .toList();
    final buf = StringBuffer()
      ..writeln('*TOWN TREASURE GROCERIES*')
      ..writeln('*${pl.name}*')
      ..writeln();

    final grouped = <String, List<PriceListItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.category, () => []).add(item);
    }

    grouped.forEach((cat, catItems) {
      buf.writeln('*${cat.toUpperCase()}*');
      for (final i in catItems) {
        final notes = i.notes.trim().isNotEmpty ? ' (${i.notes.trim()})' : '';
        buf.writeln(
          '  - ${i.name} — KES ${formatMoney(i.price)} / ${i.unit}$notes',
        );
      }
      buf.writeln();
    });

    buf
      ..writeln('Orders: 0708567696')
      ..writeln('Email: thetowntreasure25@gmail.com')
      ..write('Prices subject to market changes');
    return buf.toString();
  }
}
