import 'dart:math';

import 'invoice.dart';

/// Resolution outcome when matching a raw restaurant name against saved clients.
enum RestaurantResolutionStatus {
  empty,
  matched,
  ambiguous,
  suggested,
  possible,
  unmatched,
}

class RestaurantCandidate {
  const RestaurantCandidate({required this.restaurant, required this.score});

  final Restaurant restaurant;
  final double score;
}

class RestaurantResolution {
  const RestaurantResolution({
    required this.status,
    this.restaurant,
    this.method,
    this.score = 0,
    this.candidates = const [],
  });

  final RestaurantResolutionStatus status;
  final Restaurant? restaurant;
  final String? method;
  final double score;
  final List<RestaurantCandidate> candidates;
}

/// How a client prefers KRA eTIMS Tax Invoices to be issued.
enum EtimsCadence {
  none('none', 'Not Required'),
  daily('daily', 'Daily (Per Invoice)'),
  monthly('monthly', 'Monthly (Consolidated)');

  const EtimsCadence(this.code, this.label);
  final String code;
  final String label;

  static EtimsCadence fromCode(String? raw) {
    final norm = (raw ?? '').trim().toLowerCase();
    for (final value in EtimsCadence.values) {
      if (value.code == norm) return value;
    }
    return EtimsCadence.none;
  }
}

/// Restaurant client entity matching the `restaurants` collection in `data.js` & `nav.js`.
class Restaurant {
  const Restaurant({
    required this.id,
    required this.name,
    this.kraPin = '',
    this.etimsCadence = EtimsCadence.none,
    this.aliases = const [],
    this.contact = '',
    this.phone = '',
    this.address = '',
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String kraPin;
  final EtimsCadence etimsCadence;
  final List<String> aliases;
  final String contact;
  final String phone;
  final String address;
  final String? createdAt;
  final String? updatedAt;

  static final RegExp _kraPinPattern = RegExp(r'^[PA][0-9]{9}[A-Z]$');
  static final RegExp _genericWordsPattern = RegExp(
    r'\b(the|hotel|hotels|restaurant|restaurants|suites|resort|club|inn|lodge|limited|ltd)\b',
  );
  static final RegExp _internalContactPlaceholderPattern = RegExp(
    r'^(?:added\s+(?:from|via|by)\s+clerk(?:\s+approval)?|from\s+clerk(?:\s+approval)?|clerk\s+approval|submitted\s+by\s+clerk.*|auto[\s\-]?(?:created|added).*|created\s+(?:from|via|by)\s+clerk.*|system\s+generated.*|generated\s+in\s+branded.*|imported\s+from.*|n/?a|none|null|undefined|-+)$',
    caseSensitive: false,
  );

  /// Strips internal audit/schema placeholders (e.g. `"Added from clerk approval"`)
  /// so internal workflow notes never appear as a client's contact name on PDFs,
  /// WhatsApp greetings, or recipient cards.
  static String sanitizeContact(String? raw) {
    final trimmed = (raw ?? '').trim();
    if (trimmed.isEmpty) return '';
    if (_internalContactPlaceholderPattern.hasMatch(trimmed)) return '';
    final lower = trimmed.toLowerCase();
    if (lower.contains('clerk approval') ||
        lower.contains('added via clerk') ||
        lower.contains('added from clerk') ||
        lower.contains('submitted by clerk')) {
      return '';
    }
    return trimmed;
  }

  /// Returns `true` when [rawPhone] resolves to Town Treasure Limited's own
  /// supplier phone (`0708 567 696` / `+254 708 567 696`).
  static bool isOwnCompanyPhone(String? rawPhone) {
    final digits = (rawPhone ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return false;
    return digits == '0708567696' ||
        digits == '254708567696' ||
        digits == '708567696';
  }

  /// Sanitizes a client phone number for external display/WhatsApp routing,
  /// suppressing Town Treasure's own supplier phone or placeholder tokens.
  static String sanitizeClientPhone(String? rawPhone) {
    final trimmed = (rawPhone ?? '').trim();
    if (trimmed.isEmpty) return '';
    if (isOwnCompanyPhone(trimmed)) return '';
    if (RegExp(r'^(?:n/?a|none|null|undefined|-+)$', caseSensitive: false)
        .hasMatch(trimmed)) {
      return '';
    }
    return trimmed;
  }

  /// Sanitizes a client address for external display, removing internal placeholders.
  static String sanitizeClientAddress(String? rawAddress) {
    final trimmed = (rawAddress ?? '').trim();
    if (trimmed.isEmpty) return '';
    if (_internalContactPlaceholderPattern.hasMatch(trimmed)) return '';
    if (trimmed.toLowerCase() == 'thetowntreasure25@gmail.com') return '';
    return trimmed;
  }

  /// Normalizes a KRA PIN by trimming, uppercasing, and stripping whitespace.
  static String normalizeKraPin(String? pin) {
    return (pin ?? '').trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
  }

  /// Validates an 11-character Kenyan KRA PIN (`[PA][0-9]{9}[A-Z]`).
  static bool isValidKraPin(String? pin) {
    return _kraPinPattern.hasMatch(normalizeKraPin(pin));
  }

  /// Normalizes a restaurant name for exact and alias matching, matching `data.js`.
  static String normalizeRestaurantName(String? name) {
    final base = _stripCommonDiacritics(name ?? '')
        .toLowerCase()
        .replaceAll('&', ' and ')
        .replaceAll(_genericWordsPattern, ' ');
    return base.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  /// Returns all non-empty name + alias variants for a restaurant.
  static List<String> nameVariants(Restaurant? restaurant) {
    if (restaurant == null) return const [];
    return [restaurant.name, ...restaurant.aliases]
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
  }

  /// Normalized Levenshtein similarity matching `restaurantNameEditSimilarity` in `data.js`.
  static double restaurantNameEditSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    if (min(a.length, b.length) < 4) return 0;
    var previous = List<int>.generate(b.length + 1, (index) => index);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0);
      current[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = min(
          current[j - 1] + 1,
          min(previous[j] + 1, previous[j - 1] + cost),
        );
      }
      previous = current;
    }
    return 1 - previous[b.length] / max(a.length, b.length);
  }

  /// Combined edit and token similarity matching `restaurantNameSimilarity` in `data.js`.
  static double restaurantNameSimilarity(String a, String b) {
    final left = normalizeRestaurantName(a);
    final right = normalizeRestaurantName(b);
    if (left.isEmpty || right.isEmpty) return 0;
    final charScore = restaurantNameEditSimilarity(left, right);

    Set<String> tokens(String value) {
      final cleaned = _stripCommonDiacritics(value)
          .toLowerCase()
          .replaceAll('&', ' and ')
          .replaceAll(_genericWordsPattern, ' ');
      return RegExp(r'[a-z0-9]+')
          .allMatches(cleaned)
          .map((m) => m.group(0)!)
          .toSet();
    }

    final leftTokens = tokens(a);
    final rightTokens = tokens(b);
    final shared = leftTokens.where(rightTokens.contains).length;
    final tokenScore =
        (2 * shared) / max(1, leftTokens.length + rightTokens.length);
    return max(charScore, tokenScore);
  }

  /// Conservative name resolver matching `resolveRestaurantName` in `data.js`.
  static RestaurantResolution resolveName(
    String? name,
    List<Restaurant> restaurants,
  ) {
    final key = normalizeRestaurantName(name);
    final records = restaurants
        .where((r) => r.id.isNotEmpty && r.name.isNotEmpty)
        .toList();
    if (key.isEmpty) {
      return const RestaurantResolution(status: RestaurantResolutionStatus.empty);
    }

    final exact = records.where((r) {
      return [r.name, ...r.aliases]
          .any((value) => normalizeRestaurantName(value) == key);
    }).toList();

    if (exact.length == 1) {
      final restaurant = exact.first;
      final method =
          normalizeRestaurantName(restaurant.name) == key ? 'name' : 'alias';
      return RestaurantResolution(
        status: RestaurantResolutionStatus.matched,
        restaurant: restaurant,
        method: method,
        score: 1,
        candidates: [RestaurantCandidate(restaurant: restaurant, score: 1)],
      );
    }
    if (exact.length > 1) {
      return RestaurantResolution(
        status: RestaurantResolutionStatus.ambiguous,
        candidates: exact
            .map((r) => RestaurantCandidate(restaurant: r, score: 1))
            .toList(),
      );
    }
    if (key.length < 3) {
      return const RestaurantResolution(
        status: RestaurantResolutionStatus.unmatched,
      );
    }

    final ranked = <RestaurantCandidate>[];
    for (final r in records) {
      final variants = [r.name, ...r.aliases];
      var best = 0.0;
      for (final variant in variants) {
        final s = restaurantNameSimilarity(name ?? '', variant);
        if (s > best) best = s;
      }
      if (best >= 0.50) {
        ranked.add(RestaurantCandidate(restaurant: r, score: best));
      }
    }
    ranked.sort((a, b) {
      final scoreCmp = b.score.compareTo(a.score);
      if (scoreCmp != 0) return scoreCmp;
      return a.restaurant.name.compareTo(b.restaurant.name);
    });

    if (ranked.isEmpty) {
      return const RestaurantResolution(
        status: RestaurantResolutionStatus.unmatched,
      );
    }
    final first = ranked[0];
    final secondScore = ranked.length > 1 ? ranked[1].score : 0.0;
    final margin = first.score - secondScore;

    if (first.score >= 0.64 && margin >= 0.12) {
      return RestaurantResolution(
        status: RestaurantResolutionStatus.suggested,
        restaurant: first.restaurant,
        score: first.score,
        candidates: ranked.take(3).toList(),
      );
    }
    if (first.score >= 0.62 && margin < 0.12) {
      return RestaurantResolution(
        status: RestaurantResolutionStatus.ambiguous,
        candidates: ranked
            .where((item) => first.score - item.score < 0.12)
            .take(3)
            .toList(),
      );
    }
    return RestaurantResolution(
      status: RestaurantResolutionStatus.possible,
      score: first.score,
      candidates: ranked.take(3).toList(),
    );
  }

  /// Follows overlapping names and aliases so a merge absorbs the full duplicate group.
  static List<Restaurant> collectMergeCandidates(
    Restaurant target,
    List<Restaurant> existing,
  ) {
    final keys = nameVariants(target)
        .map(normalizeRestaurantName)
        .where((k) => k.isNotEmpty)
        .toSet();
    final merged = <String, Restaurant>{};
    var changed = true;
    while (changed) {
      changed = false;
      for (final candidate in existing) {
        if (candidate.id == target.id || merged.containsKey(candidate.id)) {
          continue;
        }
        final variants = nameVariants(candidate)
            .map(normalizeRestaurantName)
            .where((k) => k.isNotEmpty)
            .toList();
        if (!variants.any(keys.contains)) continue;
        merged[candidate.id] = candidate;
        keys.addAll(variants);
        changed = true;
      }
    }
    return merged.values.toList();
  }

  /// Resolves an invoice to a restaurant by ID first, then exact name/alias.
  static RestaurantResolution resolveInvoiceRestaurant(
    Invoice invoice,
    List<Restaurant> restaurants,
  ) {
    if (invoice.restaurantId.isNotEmpty) {
      for (final r in restaurants) {
        if (r.id == invoice.restaurantId) {
          return RestaurantResolution(
            status: RestaurantResolutionStatus.matched,
            restaurant: r,
            method: 'id',
            score: 1,
          );
        }
      }
    }
    final byName = resolveName(invoice.restaurantName, restaurants);
    if (byName.status == RestaurantResolutionStatus.matched) {
      return RestaurantResolution(
        status: byName.status,
        restaurant: byName.restaurant,
        method: 'legacy-name',
        score: byName.score,
        candidates: byName.candidates,
      );
    }
    return byName;
  }

  static bool invoiceBelongsToRestaurant(
    Invoice invoice,
    Restaurant restaurant,
    List<Restaurant> restaurants,
  ) {
    final resolved = resolveInvoiceRestaurant(invoice, restaurants);
    return resolved.status == RestaurantResolutionStatus.matched &&
        resolved.restaurant?.id == restaurant.id;
  }

  static String invoiceDisplayName(
    Invoice invoice,
    List<Restaurant> restaurants,
  ) {
    final resolved = resolveInvoiceRestaurant(invoice, restaurants);
    if (resolved.status == RestaurantResolutionStatus.matched &&
        resolved.restaurant != null) {
      return resolved.restaurant!.name;
    }
    return invoice.restaurantName.isNotEmpty
        ? invoice.restaurantName
        : 'Unknown';
  }

  factory Restaurant.fromJson(Map<String, dynamic> json) {
    final rawAliases = json['aliases'];
    final aliases = rawAliases is List
        ? rawAliases
            .map((e) => (e ?? '').toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : <String>[];

    return Restaurant(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      kraPin: normalizeKraPin(json['kraPin']?.toString()),
      etimsCadence: EtimsCadence.fromCode(json['etimsCadence']?.toString()),
      aliases: aliases,
      contact: sanitizeContact(json['contact']?.toString()),
      phone: (json['phone'] ?? '').toString(),
      address: sanitizeClientAddress(json['address']?.toString()),
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'kraPin': kraPin,
      if (etimsCadence != EtimsCadence.none) 'etimsCadence': etimsCadence.code,
      'aliases': aliases,
      'contact': contact,
      'phone': phone,
      'address': address,
      if (createdAt != null) 'createdAt': createdAt,
      if (updatedAt != null) 'updatedAt': updatedAt,
    };
  }

  Restaurant copyWith({
    String? id,
    String? name,
    String? kraPin,
    EtimsCadence? etimsCadence,
    List<String>? aliases,
    String? contact,
    String? phone,
    String? address,
    String? createdAt,
    String? updatedAt,
  }) {
    return Restaurant(
      id: id ?? this.id,
      name: name ?? this.name,
      kraPin: kraPin ?? this.kraPin,
      etimsCadence: etimsCadence ?? this.etimsCadence,
      aliases: aliases ?? this.aliases,
      contact: contact ?? this.contact,
      phone: phone ?? this.phone,
      address: address ?? this.address,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static String _stripCommonDiacritics(String input) {
    const map = {
      'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
      'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
      'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
      'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
      'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
      'ñ': 'n', 'ç': 'c',
      'Á': 'A', 'À': 'A', 'Â': 'A', 'Ä': 'A', 'Ã': 'A', 'Å': 'A',
      'É': 'E', 'È': 'E', 'Ê': 'E', 'Ë': 'E',
      'Í': 'I', 'Ì': 'I', 'Î': 'I', 'Ï': 'I',
      'Ó': 'O', 'Ò': 'O', 'Ô': 'O', 'Ö': 'O', 'Õ': 'O',
      'Ú': 'U', 'Ù': 'U', 'Û': 'U', 'Ü': 'U',
      'Ñ': 'N', 'Ç': 'C',
    };
    final buf = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      final code = ch.codeUnitAt(0);
      // Skip combining diacritical marks if input was already NFKD-decomposed.
      if (code >= 0x0300 && code <= 0x036F) continue;
      buf.write(map[ch] ?? ch);
    }
    return buf.toString();
  }
}
