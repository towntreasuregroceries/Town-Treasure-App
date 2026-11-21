import 'package:flutter/foundation.dart';

import '../../../data/repositories/vault_repository.dart';
import '../../../domain/models/models.dart';

/// Candidate restaurant with similarity score for duplicate review.
class SimilarRestaurantMatch {
  const SimilarRestaurantMatch({
    required this.restaurant,
    required this.score,
  });

  final Restaurant restaurant;
  final double score;
}

/// Pre-save validation and duplicate detection result matching `nav.js`.
class RestaurantSaveCheck {
  const RestaurantSaveCheck({
    this.error,
    this.candidate,
    this.isNew = false,
    this.duplicates = const [],
    this.fuzzyCandidates = const [],
  });

  final String? error;
  final Restaurant? candidate;
  final bool isNew;
  final List<Restaurant> duplicates;
  final List<Restaurant> fuzzyCandidates;

  bool get hasError => error != null && error!.isNotEmpty;
  bool get needsFuzzyConfirmation => fuzzyCandidates.isNotEmpty;
  bool get needsMergeConfirmation => duplicates.isNotEmpty;
}

/// Outcome of a mutating restaurant action including sync confirmation status.
class RestaurantActionResult {
  const RestaurantActionResult({
    required this.ok,
    required this.synced,
    required this.title,
    required this.message,
  });

  final bool ok;
  final bool synced;
  final String title;
  final String message;
}

/// ViewModel for Restaurant client management with 100% logic parity to `nav.js` & `data.js`.
class RestaurantsViewModel extends ChangeNotifier {
  RestaurantsViewModel({required this._vault}) {
    _vault.addListener(_onVaultChanged);
  }

  final VaultRepository _vault;
  String _searchQuery = '';
  bool _isBusy = false;

  String get searchQuery => _searchQuery;
  bool get isBusy => _isBusy;

  List<Restaurant> get allRestaurants => _vault.restaurants;

  List<Restaurant> get filteredRestaurants {
    final q = _searchQuery.trim().toLowerCase();
    final list = _vault.restaurants;
    if (q.isEmpty) return list;
    return list.where((r) {
      if (r.name.toLowerCase().contains(q)) return true;
      if (r.kraPin.toLowerCase().contains(q)) return true;
      if (r.contact.toLowerCase().contains(q)) return true;
      if (r.phone.toLowerCase().contains(q)) return true;
      if (r.address.toLowerCase().contains(q)) return true;
      return r.aliases.any((a) => a.toLowerCase().contains(q));
    }).toList();
  }

  void setSearchQuery(String query) {
    if (_searchQuery == query) return;
    _searchQuery = query;
    notifyListeners();
  }

  /// Total non-draft invoiced sales attributed to [restaurant].
  double totalSalesFor(Restaurant restaurant) {
    final rests = _vault.restaurants;
    var total = 0.0;
    for (final inv in _vault.invoices) {
      if (inv.isDraft) continue;
      if (Restaurant.invoiceBelongsToRestaurant(inv, restaurant, rests)) {
        total += inv.totalSell;
      }
    }
    return total;
  }

  /// Count of non-draft invoices attributed to [restaurant].
  int invoiceCountFor(Restaurant restaurant) {
    final rests = _vault.restaurants;
    var count = 0;
    for (final inv in _vault.invoices) {
      if (inv.isDraft) continue;
      if (Restaurant.invoiceBelongsToRestaurant(inv, restaurant, rests)) {
        count++;
      }
    }
    return count;
  }

  /// Finds non-exact similar records (`score >= 0.50`) matching `findSimilarRestaurantRecords` in `data.js`.
  List<SimilarRestaurantMatch> findSimilarRecords(
    Restaurant target, [
    List<Restaurant>? pool,
  ]) {
    final restaurants = pool ?? _vault.restaurants;
    final variants = Restaurant.nameVariants(target);
    if (variants.isEmpty) return const [];

    final matches = <SimilarRestaurantMatch>[];
    for (final other in restaurants) {
      if (other.id == target.id) continue;
      final otherVariants = Restaurant.nameVariants(other);
      var best = 0.0;
      for (final a in variants) {
        for (final b in otherVariants) {
          final score = Restaurant.restaurantNameSimilarity(a, b);
          if (score > best) best = score;
        }
      }
      if (best >= 0.50) {
        matches.add(SimilarRestaurantMatch(restaurant: other, score: best));
      }
    }

    matches.sort((a, b) {
      final scoreCmp = b.score.compareTo(a.score);
      if (scoreCmp != 0) return scoreCmp;
      return a.restaurant.name.compareTo(b.restaurant.name);
    });
    return matches;
  }

  /// Disambiguated dropdown/picker label matching `restaurantOptionLabel` in `data.js`.
  String optionLabel(Restaurant restaurant) {
    final restaurants = _vault.restaurants;
    final variants = Restaurant.nameVariants(restaurant)
        .map(Restaurant.normalizeRestaurantName)
        .where((v) => v.isNotEmpty)
        .toSet();

    final conflicts = restaurants.where((other) {
      if (other.id == restaurant.id) return false;
      return Restaurant.nameVariants(other).any(
        (name) => variants.contains(Restaurant.normalizeRestaurantName(name)),
      );
    }).toList();

    final conflictIds = conflicts.map((c) => c.id).toSet();
    final similar = findSimilarRecords(restaurant, restaurants)
        .where((c) => !conflictIds.contains(c.restaurant.id))
        .toList();

    final detail = [
      restaurant.address,
      restaurant.phone,
      restaurant.contact,
    ].where((s) => s.trim().isNotEmpty).join(' | ');
    final suffixLen = restaurant.id.length;
    final recordId = suffixLen > 6
        ? restaurant.id.substring(suffixLen - 6)
        : restaurant.id;

    if (conflicts.isNotEmpty) {
      final prefix = detail.isNotEmpty ? '$detail | ' : '';
      return '${restaurant.name} (${prefix}record $recordId)';
    }
    if (similar.isNotEmpty) {
      final simNames =
          similar.take(2).map((item) => item.restaurant.name).join(', ');
      return '${restaurant.name} (possible duplicate: $simNames)';
    }
    return restaurant.name;
  }

  /// Validates form inputs and checks for exact/transitive & fuzzy duplicates (`saveRestaurant` in `nav.js`).
  RestaurantSaveCheck prepareSave({
    String? existingId,
    required String name,
    String aliasesRaw = '',
    String kraPinRaw = '',
    EtimsCadence etimsCadence = EtimsCadence.none,
    String contact = '',
    String phone = '',
    String address = '',
  }) {
    final trimmedName = name.trim();
    final kraPin = Restaurant.normalizeKraPin(kraPinRaw);
    if (kraPin.isNotEmpty && !Restaurant.isValidKraPin(kraPin)) {
      return const RestaurantSaveCheck(
        error:
            'Enter a valid 11-character KRA PIN (e.g. P051234567X) or leave blank.',
      );
    }
    if (trimmedName.isEmpty) {
      return const RestaurantSaveCheck(error: 'Name is required.');
    }
    final canonicalKey = Restaurant.normalizeRestaurantName(trimmedName);
    if (canonicalKey.isEmpty) {
      return const RestaurantSaveCheck(
        error:
            'Enter a specific restaurant name; generic words alone are not enough.',
      );
    }

    final aliasSeen = <String>{};
    final parsedAliases = <String>[];
    for (final part in aliasesRaw.split(RegExp(r'[\n,;]+'))) {
      final trimmed = part.trim();
      final key = Restaurant.normalizeRestaurantName(trimmed);
      if (key.isEmpty || key == canonicalKey || aliasSeen.contains(key)) {
        continue;
      }
      aliasSeen.add(key);
      parsedAliases.add(trimmed);
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final list = _vault.restaurants;
    final hasId = existingId != null && existingId.isNotEmpty;
    final existingIdx =
        hasId ? list.indexWhere((x) => x.id == existingId) : -1;
    final isNew = existingIdx < 0;

    final String createdAt;
    if (!isNew) {
      final previous = list[existingIdx];
      createdAt = previous.createdAt ?? now;
      if (Restaurant.normalizeRestaurantName(previous.name) != canonicalKey &&
          previous.name.trim().isNotEmpty) {
        parsedAliases.add(previous.name.trim());
      }
    } else {
      createdAt = now;
    }

    final finalAliasKeys = <String>{};
    final finalAliases = <String>[];
    for (final alias in parsedAliases) {
      final key = Restaurant.normalizeRestaurantName(alias);
      if (key.isEmpty || key == canonicalKey || finalAliasKeys.contains(key)) {
        continue;
      }
      finalAliasKeys.add(key);
      finalAliases.add(alias);
    }

    final candidate = Restaurant(
      id: hasId ? existingId : AppHelpers.genId(),
      name: trimmedName,
      kraPin: kraPin,
      etimsCadence: etimsCadence,
      aliases: finalAliases,
      contact: contact.trim(),
      phone: phone.trim(),
      address: address.trim(),
      createdAt: createdAt,
      updatedAt: now,
    );

    final otherRestaurants =
        list.where((x) => x.id != candidate.id).toList();
    final duplicates =
        Restaurant.collectMergeCandidates(candidate, otherRestaurants);
    if (isNew && duplicates.isNotEmpty) {
      return RestaurantSaveCheck(
        error:
            '"${duplicates.first.name}" already exists. Edit it and add other spellings as aliases.',
      );
    }

    final duplicateIds = duplicates.map((d) => d.id).toSet();
    final fuzzyMap = <String, Restaurant>{};
    for (final variant in Restaurant.nameVariants(candidate)) {
      final resolution = Restaurant.resolveName(variant, otherRestaurants);
      for (final item in resolution.candidates) {
        if (!duplicateIds.contains(item.restaurant.id)) {
          fuzzyMap[item.restaurant.id] = item.restaurant;
        }
      }
    }

    return RestaurantSaveCheck(
      candidate: candidate,
      isNew: isNew,
      duplicates: duplicates,
      fuzzyCandidates: fuzzyMap.values.toList(),
    );
  }

  /// Persists [candidate], absorbs [duplicates], reassigns invoices, and syncs (`saveRestaurantRecord` in `nav.js`).
  Future<RestaurantActionResult> commitSave(
    Restaurant candidate, {
    required bool isNew,
    List<Restaurant> duplicates = const [],
  }) async {
    _isBusy = true;
    notifyListeners();
    try {
      final duplicateIds = duplicates.map((d) => d.id).toSet();
      final now = DateTime.now().toUtc().toIso8601String();
      final targetNorm = Restaurant.normalizeRestaurantName(candidate.name);

      final mergedNames = <String>{
        ...Restaurant.nameVariants(candidate)
            .map(Restaurant.normalizeRestaurantName)
            .where((k) => k.isNotEmpty),
        ...duplicates
            .expand(Restaurant.nameVariants)
            .map(Restaurant.normalizeRestaurantName)
            .where((k) => k.isNotEmpty),
      };

      final aliasKeys = <String>{};
      final mergedAliases = <String>[];
      final combinedVariants = <String>[
        ...candidate.aliases,
        ...duplicates.expand(Restaurant.nameVariants),
      ];
      for (final alias in combinedVariants) {
        final key = Restaurant.normalizeRestaurantName(alias);
        if (key.isEmpty || key == targetNorm || aliasKeys.contains(key)) {
          continue;
        }
        aliasKeys.add(key);
        mergedAliases.add(alias);
      }

      var fallbackPin = '';
      var fallbackCadence = candidate.etimsCadence;
      for (final dup in duplicates) {
        final normPin = Restaurant.normalizeKraPin(dup.kraPin);
        if (fallbackPin.isEmpty && normPin.isNotEmpty) {
          fallbackPin = normPin;
        }
        if (fallbackCadence == EtimsCadence.none &&
            dup.etimsCadence != EtimsCadence.none) {
          fallbackCadence = dup.etimsCadence;
        }
      }

      final finalRecord = candidate.copyWith(
        kraPin: candidate.kraPin.isNotEmpty ? candidate.kraPin : fallbackPin,
        etimsCadence: fallbackCadence,
        aliases: mergedAliases,
        updatedAt: now,
      );

      if (duplicateIds.isNotEmpty) {
        final activeIds = _vault.restaurants.map((r) => r.id).toSet();

        Invoice canonicalize(Invoice invoice) {
          final shouldReassign = duplicateIds.contains(invoice.restaurantId) ||
              invoice.restaurantId == finalRecord.id ||
              (!activeIds.contains(invoice.restaurantId) &&
                  mergedNames.contains(
                    Restaurant.normalizeRestaurantName(invoice.restaurantName),
                  ));
          if (!shouldReassign) return invoice;
          return invoice.copyWith(
            restaurantId: finalRecord.id,
            restaurantName: finalRecord.name,
            updatedAt: now,
          );
        }

        final nextDeletedRestIds = <String>{
          ..._vault.deletedRestaurantIds,
          ...duplicateIds,
        }.toList();
        await _vault.setDeletedRestaurantIds(nextDeletedRestIds, sync: false);
        await _vault.setInvoices(
          _vault.invoices.map(canonicalize).toList(),
          sync: false,
        );
        await _vault.setDeletedInvoices(
          _vault.deletedInvoices.map(canonicalize).toList(),
          sync: false,
        );
      }

      final nextList = _vault.restaurants
          .where((existing) => !duplicateIds.contains(existing.id))
          .toList();
      final idx = nextList.indexWhere((x) => x.id == finalRecord.id);
      if (idx >= 0) {
        nextList[idx] = finalRecord;
      } else {
        nextList.add(finalRecord);
      }
      await _vault.setRestaurants(nextList, sync: false);

      final synced = await _vault.syncNow();
      final actionMsg = duplicates.isNotEmpty
          ? 'Restaurant saved; merged ${duplicates.length} duplicate restaurant record${duplicates.length == 1 ? '' : 's'}.'
          : (isNew ? 'Restaurant added' : 'Restaurant updated');

      return RestaurantActionResult(
        ok: true,
        synced: synced,
        title: synced ? 'Restaurant saved' : 'Restaurant saved on this device',
        message: synced
            ? '$actionMsg. Changes synced to the account.'
            : '$actionMsg on this device, but cloud sync was not confirmed.',
      );
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  /// Counts linked active + recycled invoices before deletion (`deleteRestaurant` in `nav.js`).
  int countLinkedInvoices(Restaurant restaurant) {
    final allRestaurants = _vault.restaurants;
    final allInvoices = [..._vault.invoices, ..._vault.deletedInvoices];
    var count = 0;
    for (final inv in allInvoices) {
      if (Restaurant.invoiceBelongsToRestaurant(
        inv,
        restaurant,
        allRestaurants,
      )) {
        count++;
      }
    }
    return count;
  }

  /// Deletes a restaurant if it has zero active or recycled linked invoices.
  Future<RestaurantActionResult> deleteRestaurant(String id) async {
    final idx = _vault.restaurants.indexWhere((x) => x.id == id);
    if (idx < 0) {
      return const RestaurantActionResult(
        ok: false,
        synced: false,
        title: 'Not found',
        message: 'Restaurant record was not found.',
      );
    }
    final restaurant = _vault.restaurants[idx];
    final references = countLinkedInvoices(restaurant);
    if (references > 0) {
      return RestaurantActionResult(
        ok: false,
        synced: false,
        title: 'Cannot delete ${restaurant.name}',
        message:
            'Cannot delete ${restaurant.name}: $references active or recycled invoice(s) are linked to it. Edit the restaurant and merge aliases into the correct record instead.',
      );
    }

    _isBusy = true;
    notifyListeners();
    try {
      final deletedIds = <String>{..._vault.deletedRestaurantIds, id}.toList();
      await _vault.setDeletedRestaurantIds(deletedIds, sync: false);
      await _vault.setRestaurants(
        _vault.restaurants.where((x) => x.id != id).toList(),
        sync: false,
      );
      final synced = await _vault.syncNow();
      return RestaurantActionResult(
        ok: true,
        synced: synced,
        title: synced ? 'Restaurant deleted' : 'Restaurant deleted on device',
        message: synced
            ? 'The restaurant was deleted and synced to your account.'
            : 'The restaurant is removed on this device, but cloud sync was not confirmed.',
      );
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  void _onVaultChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _vault.removeListener(_onVaultChanged);
    super.dispose();
  }
}
