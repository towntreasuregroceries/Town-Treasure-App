import 'dart:math';

import 'package:intl/intl.dart';

import '../../../domain/models/models.dart';

/// Shared formatting, CSV conversion, and duplicate-detection helpers
/// matching `data.js`, `ocr-consensus.js`, and `duplicate-detector.js`.
class InvoiceFormatters {
  InvoiceFormatters._();

  static final NumberFormat _moneyFormat = NumberFormat('#,##0.00', 'en_US');

  static const List<String> supportedUnits = [
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
    'bunches',
    'heads',
    'punnets',
  ];

  static String formatMoney(double amount) {
    return _moneyFormat.format(amount.isFinite ? amount : 0.0);
  }

  /// Formats `YYYY-MM-DD` / ISO date as `DD/MM/YYYY` matching `fmtDate` in `data.js`.
  static String formatDisplayDate(String? value) {
    if (value == null || value.trim().isEmpty) return '-';
    final date = AppHelpers.parseAppDate(value);
    if (date == null) return value;
    final dd = date.day.toString().padLeft(2, '0');
    final mm = date.month.toString().padLeft(2, '0');
    final yyyy = date.year.toString().padLeft(4, '0');
    return '$dd/$mm/$yyyy';
  }

  /// Extracts a normalized `YYYY-MM` month key from any supported date string.
  static String monthKeyFromDate(String? value) {
    final normalized = AppHelpers.normalizeAppDate(value);
    if (normalized.length < 7) return '';
    return normalized.substring(0, 7);
  }

  /// Formats a `YYYY-MM` month key into a human-friendly label (e.g. `Nov 2026`).
  static String formatMonthLabel(String yearMonth) {
    if (yearMonth.trim().isEmpty) return 'All Months';
    final parts = yearMonth.split('-');
    if (parts.length < 2) return yearMonth;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (y == null || m == null || m < 1 || m > 12) return yearMonth;
    return DateFormat('MMM yyyy').format(DateTime(y, m, 1));
  }

  static String todayIso() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String normalizeUnit(String? rawUnit) {
    final clean = (rawUnit ?? '').trim().toLowerCase();
    if (clean.isEmpty || clean == 'kg') return 'kgs';
    if (clean == 'pcs' || clean == 'pc') return 'pieces';
    if (clean == 'pnts') return 'punnets';
    if (clean == 'banch') return 'bunch';
    if (supportedUnits.contains(clean)) return clean;
    return clean;
  }

  /// Serializes line items to CSV matching `OCRConsensus.itemsToCSV`.
  static String itemsToCsv(List<InvoiceLineItem> items) {
    const headers = 'Item Description,Quantity,Unit,Unit Price,Total';
    final rows = items.map((it) {
      final escaped = it.desc.replaceAll('"', '""');
      final total = it.total > 0 ? it.total : (it.qty * it.sellPrice);
      return '"$escaped",${it.qty},${it.unit.isNotEmpty ? it.unit : 'kgs'},${it.sellPrice},$total';
    });
    return [headers, ...rows].join('\n');
  }

  /// Parses CSV text into line items matching `OCRConsensus.csvToItems`.
  static List<InvoiceLineItem> csvToItems(String csvString) {
    if (csvString.trim().isEmpty) return const [];
    final lines = csvString.trim().split(RegExp(r'\r?\n'));
    if (lines.length <= 1) return const [];

    final items = <InvoiceLineItem>[];
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final parts = _splitCsvRow(line);
      if (parts.isEmpty) continue;

      final rawDesc = parts[0].trim();
      final desc = rawDesc.isEmpty ? 'Item' : rawDesc;
      final qty = parts.length > 1 ? (double.tryParse(parts[1]) ?? 1.0) : 1.0;
      final unit = parts.length > 2 && parts[2].trim().isNotEmpty
          ? normalizeUnit(parts[2])
          : 'kgs';
      final sellPrice =
          parts.length > 3 ? (double.tryParse(parts[3]) ?? 0.0) : 0.0;
      final parsedTotal =
          parts.length > 4 && parts[4].isNotEmpty ? double.tryParse(parts[4]) : null;
      final total = parsedTotal ?? (qty * sellPrice);

      items.add(
        InvoiceLineItem(
          desc: desc,
          qty: qty > 0 ? qty : 1.0,
          unit: unit,
          buyPrice: 0,
          sellPrice: sellPrice >= 0 ? sellPrice : 0,
          total: total,
        ),
      );
    }
    return items;
  }

  static List<String> _splitCsvRow(String line) {
    final parts = <String>[];
    var inQuotes = false;
    final current = StringBuffer();
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (c == ',' && !inQuotes) {
        parts.add(current.toString().trim());
        current.clear();
      } else {
        current.write(c);
      }
    }
    parts.add(current.toString().trim());
    return parts;
  }
}

/// Local heuristic ledger collision guard matching `TTGAudit` in `duplicate-detector.js`.
class InvoiceDuplicateGuard {
  InvoiceDuplicateGuard._();

  static String normalizeHotel(String name) {
    return name
        .toLowerCase()
        .replaceAll(
          RegExp(
            r'\b(the|hotel|suites|resort|restaurant|club|inn|lodge|ltd|limited|kitchen|branch)\b',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
  }

  static String canonicalProduce(String desc) =>
      AppHelpers.canonicalProduce(desc);

  static DuplicateScore calculateHeuristicScore({
    required String candidateRestaurantName,
    required String candidateDate,
    required double candidateTotalSell,
    required List<InvoiceLineItem> candidateItems,
    required Invoice existing,
  }) {
    final candHotel = normalizeHotel(candidateRestaurantName);
    final existHotel = normalizeHotel(existing.restaurantName);

    var hotelScore = 0.0;
    if (candHotel.isNotEmpty && existHotel.isNotEmpty) {
      if (candHotel == existHotel) {
        hotelScore = 1.0;
      } else if (candHotel.contains(existHotel) ||
          existHotel.contains(candHotel)) {
        hotelScore = 0.85;
      }
    }
    if (hotelScore == 0) {
      return const DuplicateScore(
        score: 0,
        hotelScore: 0,
        dateScore: 0,
        amountScore: 0,
        itemScore: 0,
        matchingItemsCount: 0,
      );
    }

    var dateScore = 0.0;
    final d1 = AppHelpers.parseAppDate(candidateDate);
    final d2 = AppHelpers.parseAppDate(existing.date);
    if (d1 != null && d2 != null) {
      final diffDays = DateTime.utc(d1.year, d1.month, d1.day)
          .difference(DateTime.utc(d2.year, d2.month, d2.day))
          .inDays
          .abs();
      if (diffDays == 0) {
        dateScore = 1.0;
      } else if (diffDays <= 1) {
        dateScore = 0.7;
      } else if (diffDays <= 3) {
        dateScore = 0.3;
      }
    }

    var amountScore = 0.0;
    if (candidateTotalSell > 0 && existing.totalSell > 0) {
      final diff = (candidateTotalSell - existing.totalSell).abs();
      if (diff <= 2) {
        amountScore = 1.0;
      } else {
        final ratio = min(candidateTotalSell, existing.totalSell) /
            max(candidateTotalSell, existing.totalSell);
        if (ratio >= 0.98) {
          amountScore = 0.85;
        } else if (ratio >= 0.85) {
          amountScore = 0.5;
        }
      }
    }

    final itemCmp = _compareItems(candidateItems, existing.items);
    final composite = (hotelScore * 0.30) +
        (dateScore * 0.25) +
        (amountScore * 0.25) +
        (itemCmp.score * 0.20);

    return DuplicateScore(
      score: min(1.0, (composite * 100).round() / 100.0),
      hotelScore: hotelScore,
      dateScore: dateScore,
      amountScore: amountScore,
      itemScore: itemCmp.score,
      matchingItemsCount: itemCmp.matchingCount,
    );
  }

  static Map<String, ({double qty, double price})> _aggregateItems(
    List<InvoiceLineItem> items,
  ) {
    final grouped = <String, ({double qty, double price})>{};
    for (final item in items) {
      final canonical = canonicalProduce(item.desc);
      if (canonical.isEmpty) continue;
      final q = item.qty > 0 ? item.qty : 1.0;
      final p = item.sellPrice > 0 ? item.sellPrice : item.buyPrice;
      final existing = grouped[canonical];
      if (existing == null) {
        grouped[canonical] = (qty: q, price: p);
      } else {
        final nextQty = existing.qty + q;
        final nextPrice = nextQty > 0
            ? ((existing.qty * existing.price) + (q * p)) / nextQty
            : max(existing.price, p);
        grouped[canonical] = (qty: nextQty, price: nextPrice);
      }
    }
    return grouped;
  }

  static _ItemComparison _compareItems(
    List<InvoiceLineItem> itemsA,
    List<InvoiceLineItem> itemsB,
  ) {
    final normA = _aggregateItems(itemsA);
    final normB = _aggregateItems(itemsB);

    if (normA.isEmpty || normB.isEmpty) {
      return const _ItemComparison(score: 0, matchingCount: 0);
    }

    var matchingCount = 0;
    var matchScoreSum = 0.0;
    for (final entry in normA.entries) {
      final b = normB[entry.key];
      if (b == null) continue;
      final a = entry.value;
      final maxQty = max(a.qty, b.qty);
      final qtyRatio = maxQty > 0 ? min(a.qty, b.qty) / maxQty : 1.0;
      final priceMatch = (a.price > 0 && b.price > 0)
          ? min(a.price, b.price) / max(a.price, b.price)
          : 1.0;
      final itemScore = 0.5 + (0.3 * qtyRatio) + (0.2 * priceMatch);
      matchingCount++;
      matchScoreSum += itemScore;
    }

    final unionCount = {...normA.keys, ...normB.keys}.length;
    final jaccardScore = unionCount > 0 ? (matchScoreSum / unionCount) : 0.0;
    return _ItemComparison(
      score: min(1.0, jaccardScore),
      matchingCount: matchingCount,
    );
  }

  static bool isHighConfidenceDuplicate(DuplicateScore s) {
    return s.hotelScore >= 0.85 &&
        s.dateScore == 1.0 &&
        s.matchingItemsCount > 0 &&
        ((s.amountScore >= 0.85 && s.itemScore >= 0.55) ||
            (s.amountScore == 1.0 && s.itemScore >= 0.45));
  }
}

class _ItemComparison {
  const _ItemComparison({required this.score, required this.matchingCount});

  final double score;
  final int matchingCount;
}

class DuplicateScore {
  const DuplicateScore({
    required this.score,
    required this.hotelScore,
    required this.dateScore,
    required this.amountScore,
    required this.itemScore,
    required this.matchingItemsCount,
  });

  final double score;
  final double hotelScore;
  final double dateScore;
  final double amountScore;
  final double itemScore;
  final int matchingItemsCount;
}
