import 'dart:math';

/// Shared date, ID, and JSON parsing helpers matching `data.js`.
class AppHelpers {
  AppHelpers._();

  static final Random _random = Random();

  /// Generates a compact unique ID matching `genId()` in `data.js`.
  static String genId() {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = (_random.nextDouble() * 1e9)
        .floor()
        .toRadixString(36)
        .padLeft(5, '0');
    return '$ts${rand.substring(0, min(5, rand.length))}';
  }

  /// Normalizes date inputs (`YYYY-MM-DD`, `YYYYMMDD`, `DDMMYYYY`, `DD/MM/YYYY`, ISO)
  /// to `YYYY-MM-DD`, or empty string when invalid.
  static String normalizeAppDate(Object? value) {
    if (value == null) return '';
    if (value is DateTime) {
      return _formatIsoDate(value);
    }
    final text = value.toString().trim();
    if (text.isEmpty) return '';

    final isoPrefix = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(text);
    if (isoPrefix != null) {
      return '${isoPrefix.group(1)}-${isoPrefix.group(2)}-${isoPrefix.group(3)}';
    }

    final compactMatch = RegExp(r'^(\d{8})$').firstMatch(text);
    if (compactMatch != null) {
      final compact = compactMatch.group(1)!;
      final yfYear = int.parse(compact.substring(0, 4));
      final yfMonth = int.parse(compact.substring(4, 6));
      final yfDay = int.parse(compact.substring(6, 8));
      if (_isValidCalendarDate(yfYear, yfMonth, yfDay)) {
        return '${compact.substring(0, 4)}-${compact.substring(4, 6)}-${compact.substring(6, 8)}';
      }
      final dfYear = int.parse(compact.substring(4, 8));
      final dfMonth = int.parse(compact.substring(2, 4));
      final dfDay = int.parse(compact.substring(0, 2));
      if (_isValidCalendarDate(dfYear, dfMonth, dfDay)) {
        return '${compact.substring(4, 8)}-${compact.substring(2, 4)}-${compact.substring(0, 2)}';
      }
      return '';
    }

    final dmyMatch = RegExp(r'^(\d{2})[/-](\d{2})[/-](\d{4})$').firstMatch(text);
    if (dmyMatch != null) {
      return '${dmyMatch.group(3)}-${dmyMatch.group(2)}-${dmyMatch.group(1)}';
    }

    final parsed = DateTime.tryParse(text);
    if (parsed == null) return '';
    final local = parsed.isUtc ? parsed.toLocal() : parsed;
    return _formatIsoDate(local);
  }

  /// Parses an application date string into a local `DateTime`, or `null`.
  static DateTime? parseAppDate(Object? value) {
    final iso = normalizeAppDate(value);
    if (iso.isEmpty) return null;
    final parts = iso.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  /// Returns an 8-digit sortable key (`YYYYMMDD`), or `'00000000'`.
  static String appDateKey(Object? value) {
    final normalized = normalizeAppDate(value).replaceAll('-', '');
    return normalized.isEmpty ? '00000000' : normalized;
  }

  /// Parses an ISO timestamp or epoch milliseconds into milliseconds since epoch.
  static int parseTimestampMs(Object? value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is num) return value.toInt();
    final str = value.toString().trim();
    if (str.isEmpty) return 0;
    final asInt = int.tryParse(str);
    if (asInt != null) return asInt;
    final dt = DateTime.tryParse(str);
    return dt?.millisecondsSinceEpoch ?? 0;
  }

  static double parseDouble(Object? value, [double fallback = 0.0]) {
    if (value == null) return fallback;
    if (value is num) return value.isFinite ? value.toDouble() : fallback;
    final parsed = double.tryParse(value.toString().trim());
    if (parsed == null || !parsed.isFinite) return fallback;
    return parsed;
  }

  static int parseInt(Object? value, [int fallback = 0]) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString().trim()) ?? fallback;
  }

  static String? nullableString(Object? value) {
    if (value == null) return null;
    final s = value.toString();
    return s.isEmpty ? null : s;
  }

  /// Shared Kenyan & wholesale produce alias table (singular + plural + Swahili names).
  static const Map<String, String> produceAliases = {
    'roma tomatoes': 'tomatoes',
    'roma tomato': 'tomatoes',
    'cooking tomatoes': 'tomatoes',
    'cooking tomato': 'tomatoes',
    'salad tomatoes': 'tomatoes',
    'salad tomato': 'tomatoes',
    'local tomatoes': 'tomatoes',
    'local tomato': 'tomatoes',
    'fresh tomatoes': 'tomatoes',
    'fresh tomato': 'tomatoes',
    'cherry tomatoes': 'cherry tomatoes',
    'cherry tomato': 'cherry tomatoes',
    'tomatoes': 'tomatoes',
    'tomato': 'tomatoes',
    'potatoes (shangi)': 'potatoes',
    'shangi potatoes': 'potatoes',
    'shangi potato': 'potatoes',
    'irish potatoes': 'potatoes',
    'irish potato': 'potatoes',
    'sweet potatoes': 'sweet potatoes',
    'sweet potato': 'sweet potatoes',
    'potatoes': 'potatoes',
    'potato': 'potatoes',
    'waru': 'potatoes',
    'warus': 'potatoes',
    'sweet capsicum': 'capsicum',
    'sweet capsicum (hoho)': 'capsicum',
    'hohos': 'capsicum',
    'hoho': 'capsicum',
    'green capsicums': 'capsicum',
    'green capsicum': 'capsicum',
    'red capsicums': 'capsicum',
    'red capsicum': 'capsicum',
    'yellow capsicums': 'capsicum',
    'yellow capsicum': 'capsicum',
    'bell peppers': 'capsicum',
    'bell pepper': 'capsicum',
    'green bell pepper': 'capsicum',
    'capsicums': 'capsicum',
    'capsicum': 'capsicum',
    'dhania (coriander)': 'coriander',
    'dhania': 'coriander',
    'cilantro': 'coriander',
    'sukuma wiki': 'sukuma wiki',
    'sukuma': 'sukuma wiki',
    'collard greens': 'sukuma wiki',
    'red onions (medium)': 'red onions',
    'red onions': 'red onions',
    'red onion': 'red onions',
    'bombay onions': 'red onions',
    'bombay onion': 'red onions',
    'bulb onions': 'red onions',
    'bulb onion': 'red onions',
    'white onions': 'white onions',
    'white onion': 'white onions',
    'spring onions': 'spring onions',
    'spring onion': 'spring onions',
    'onions': 'onions',
    'onion': 'onions',
    'baby spinach': 'spinach',
    'fresh spinach': 'spinach',
    'english cucumbers': 'cucumbers',
    'english cucumber': 'cucumbers',
    'cucumbers': 'cucumbers',
    'cucumber': 'cucumbers',
    'button mushrooms': 'mushrooms',
    'button mushroom': 'mushrooms',
    'fresh mushrooms': 'mushrooms',
    'fresh mushroom': 'mushrooms',
    'mushrooms': 'mushrooms',
    'mushroom': 'mushrooms',
    'garlic (imported)': 'garlic',
    'imported garlic': 'garlic',
    'local garlic': 'garlic',
    'fresh mint': 'mint',
    'mint leaves': 'mint',
    'courgettes': 'zucchini',
    'courgette': 'zucchini',
    'zucchinis': 'zucchini',
    'zucchini': 'zucchini',
    'carrots': 'carrots',
    'carrot': 'carrots',
    'cabbages': 'cabbage',
    'cabbage': 'cabbage',
    'avocados': 'avocado',
    'avocado': 'avocado',
    'mangoes': 'mangoes',
    'mangos': 'mangoes',
    'mango': 'mangoes',
    'bananas': 'bananas',
    'banana': 'bananas',
    'oranges': 'oranges',
    'orange': 'oranges',
    'lemons': 'lemons',
    'lemon': 'lemons',
    'limes': 'limes',
    'lime': 'limes',
    'watermelons': 'watermelons',
    'watermelon': 'watermelons',
    'pineapples': 'pineapples',
    'pineapple': 'pineapples',
    'eggplants': 'eggplant',
    'eggplant': 'eggplant',
    'brinjals': 'eggplant',
    'brinjal': 'eggplant',
    'aubergines': 'eggplant',
    'aubergine': 'eggplant',
    'chillies': 'chilies',
    'chilies': 'chilies',
    'chilli': 'chilies',
    'chili': 'chilies',
    'managu': 'managu',
    'terere': 'terere',
    'kunde': 'kunde',
  };

  static const Set<String> _nonPluralS = {
    'peas',
    'beans',
    'greens',
    'oats',
    'lettuce',
    'asparagus',
    'citrus',
    'hummus',
    'lemongrass',
    'watercress',
  };

  /// Normalizes a produce line-item description so singular/plural and Kenyan
  /// market aliases resolve to the same canonical produce key.
  static String canonicalProduce(String? desc) {
    if (desc == null || desc.trim().isEmpty) return '';
    final clean = desc
        .toLowerCase()
        .replaceAll(RegExp(r'\(.*?\)'), '')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return '';

    final exactAlias = produceAliases[clean];
    if (exactAlias != null) return exactAlias;

    for (final entry in produceAliases.entries) {
      if (RegExp(r'\b' + RegExp.escape(entry.key) + r'\b').hasMatch(clean)) {
        return entry.value;
      }
    }

    final words = clean.split(' ').map(_stemWord).toList();
    final stemmed = words.join(' ').trim();
    return produceAliases[stemmed] ?? stemmed;
  }

  static String _stemWord(String word) {
    if (word.length < 4 || _nonPluralS.contains(word)) return word;
    if (word.endsWith('ies') && word.length > 4) {
      return '${word.substring(0, word.length - 3)}y';
    }
    if (word.endsWith('oes') && word.length > 4) {
      return word.substring(0, word.length - 2);
    }
    if (word.endsWith('ches') ||
        word.endsWith('shes') ||
        word.endsWith('xes') ||
        word.endsWith('zes')) {
      return word.substring(0, word.length - 2);
    }
    if (word.endsWith('s') &&
        !word.endsWith('ss') &&
        !word.endsWith('us') &&
        !word.endsWith('is')) {
      return word.substring(0, word.length - 1);
    }
    return word;
  }

  static bool _isValidCalendarDate(int year, int month, int day) {
    if (year < 1000 || month < 1 || month > 12 || day < 1 || day > 31) {
      return false;
    }
    final candidate = DateTime(year, month, day);
    return candidate.year == year &&
        candidate.month == month &&
        candidate.day == day;
  }

  static String _formatIsoDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}
