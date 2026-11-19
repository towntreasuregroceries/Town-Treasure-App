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
