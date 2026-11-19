import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/models/models.dart';

/// A localized OCR text box in original image coordinates with deskew metadata.
class OcrTextBox {
  const OcrTextBox({
    required this.text,
    required this.confidence,
    required this.centerX,
    required this.centerY,
    required this.width,
    required this.height,
    this.angle = 0,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String text;
  final double confidence;
  final double centerX;
  final double centerY;
  final double width;
  final double height;
  final double angle;
  final double left;
  final double top;
  final double right;
  final double bottom;

  factory OcrTextBox.fromMap(Map<Object?, Object?> raw) {
    double numVal(String k) {
      final v = raw[k];
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '') ?? 0;
    }

    return OcrTextBox(
      text: (raw['text'] ?? '').toString().trim(),
      confidence: numVal('confidence'),
      centerX: numVal('centerX'),
      centerY: numVal('centerY'),
      width: numVal('width'),
      height: numVal('height'),
      angle: numVal('angle'),
      left: numVal('left'),
      top: numVal('top'),
      right: numVal('right'),
      bottom: numVal('bottom'),
    );
  }
}

/// Platform interface for bundled offline PaddleOCR PP-OCRv5 ONNX inference.
abstract class PaddleOcrGateway {
  Future<List<OcrTextBox>> recognizeBoxesFromFile(String filePath);
  Future<void> close();
}

/// Live Android MethodChannel implementation backed by `PaddleOcrPlugin.kt`.
class MethodChannelPaddleOcrGateway implements PaddleOcrGateway {
  MethodChannelPaddleOcrGateway([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.towntreasuregroceries/paddle_ocr';
  final MethodChannel _channel;

  @override
  Future<List<OcrTextBox>> recognizeBoxesFromFile(String filePath) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const [];
    }
    final result = await _channel.invokeListMethod<dynamic>(
      'recognizeFile',
      {'filePath': filePath},
    );
    if (result == null) return const [];
    return result
        .whereType<Map>()
        .map((m) => OcrTextBox.fromMap(m.cast<Object?, Object?>()))
        .where((b) => b.text.isNotEmpty)
        .toList();
  }

  @override
  Future<void> close() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>('dispose');
    } catch (_) {}
  }
}

class _DeskewedBox {
  const _DeskewedBox({
    required this.box,
    required this.dx,
    required this.dy,
  });

  final OcrTextBox box;
  final double dx;
  final double dy;
}

/// Reconstructs deskewed visual table rows from 2D bounding boxes and parses
/// structured wholesale delivery dockets and produce price lists offline.
class SpatialOcrParser {
  SpatialOcrParser._();

  static const Set<String> _knownUnits = {
    'kg',
    'kgs',
    'kilogram',
    'kilograms',
    'crate',
    'crates',
    'bag',
    'bags',
    'baq',
    'baqs',
    'pc',
    'pcs',
    'piece',
    'pieces',
    'bunch',
    'bunche',
    'bunches',
    'bchs',
    'bundle',
    'bundles',
    'head',
    'heads',
    'pnt',
    'pnts',
    'punnet',
    'punnets',
    'litre',
    'litres',
    'tray',
    'trays',
    'dozen',
    'box',
    'boxes',
    'pkt',
    'pkts',
    'packet',
    'packets',
  };

  /// Estimates dominant skew angle from wide boxes, rotates coordinates flat,
  /// and clusters text boxes into left-to-right visual table rows.
  static List<List<OcrTextBox>> reconstructDeskewedRows(List<OcrTextBox> boxes) {
    final valid = boxes.where((b) => b.text.trim().isNotEmpty).toList();
    if (valid.isEmpty) return const [];

    final wideAngles = valid
        .where((b) => math.max(b.width, b.height) >= 40 && b.angle != 0)
        .map((b) => b.angle)
        .toList()
      ..sort();
    final medAngle = wideAngles.isNotEmpty
        ? wideAngles[wideAngles.length ~/ 2]
        : 0.0;
    final rad = -medAngle * (math.pi / 180.0);
    final cosA = math.cos(rad);
    final sinA = math.sin(rad);

    final deskewed = valid.map((b) {
      final dx = b.centerX * cosA - b.centerY * sinA;
      final dy = b.centerX * sinA + b.centerY * cosA;
      return _DeskewedBox(box: b, dx: dx, dy: dy);
    }).toList()
      ..sort((a, b) => a.dy.compareTo(b.dy));

    final heights = valid
        .map((b) => math.min(b.width, b.height))
        .where((h) => h > 0)
        .toList()
      ..sort();
    final medH = heights.isNotEmpty ? heights[heights.length ~/ 2] : 24.0;
    final rowThreshold = math.max(12.0, medH * 0.58);

    final rowGroups = <List<_DeskewedBox>>[];
    for (final item in deskewed) {
      if (rowGroups.isEmpty) {
        rowGroups.add([item]);
        continue;
      }
      final currentGroup = rowGroups.last;
      final anchorDy = currentGroup.fold<double>(0, (s, x) => s + x.dy) /
          currentGroup.length;
      if ((item.dy - anchorDy).abs() <= rowThreshold) {
        currentGroup.add(item);
      } else {
        rowGroups.add([item]);
      }
    }

    return rowGroups.map((group) {
      group.sort((a, b) => a.dx.compareTo(b.dx));
      return group.map((g) => g.box).toList();
    }).toList();
  }

  /// Flattens reconstructed spatial rows to aligned text lines for logging or
  /// cross-checking with plain-text parsers.
  static String rowsToPlainText(List<List<OcrTextBox>> rows) {
    return rows
        .map((row) => row.map((b) => b.text.trim()).where((s) => s.isNotEmpty).join(' '))
        .where((l) => l.isNotEmpty)
        .join('\n');
  }

  /// Normalizes common OCR substitutions on Kenyan numeric tokens
  /// (`1.OOO` -> `1000`, `IO` -> `10`, `3.200` / `36.800` -> `3200` / `36800`).
  static double parseOcrNumber(String? raw, {bool treatTripleDotAsThousands = true}) {
    if (raw == null) return 0;
    var s = raw.trim();
    if (s.isEmpty) return 0;

    // Strip common currency & rate prefixes/suffixes
    s = s.replaceAll(
      RegExp(r'(?:kesi?|ksh|@|=|/|-+$)', caseSensitive: false),
      '',
    ).trim();

    if (s.isEmpty) return 0;

    // Repair common OCR digit confusions only if token is predominantly numeric
    final repaired = s
        .replaceAll(RegExp(r'[Oo]'), '0')
        .replaceAll(RegExp(r'[Il|]'), '1');
    if (RegExp(r'^[\d,.\s]+$').hasMatch(repaired)) {
      s = repaired.replaceAll(' ', '');
    } else {
      return 0;
    }

    // Handle European/scanned thousand separators like "3.200", "36.800", "16.000"
    if (treatTripleDotAsThousands &&
        !s.contains(',') &&
        RegExp(r'^\d{1,3}(?:\.\d{3})+$').hasMatch(s)) {
      s = s.replaceAll('.', '');
    }

    s = s.replaceAll(',', '');
    return double.tryParse(s) ?? 0;
  }

  static String normalizeOcrUnit(String raw) {
    final u = raw.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '').trim();
    if (u.isEmpty) return 'kgs';
    if (u == 'baq' || u == 'baqs' || u == 'bag' || u == 'bags') return 'bags';
    if (u.startsWith('bunch') || u == 'bchs' || u == 'bunche') return 'bunches';
    if (u.startsWith('bundle')) return 'bundles';
    if (u.startsWith('pnt') || u.startsWith('punnet')) return 'pnts';
    if (u.startsWith('crate')) return 'crates';
    if (u.startsWith('head')) return 'heads';
    if (u.startsWith('pc') || u == 'piece' || u == 'pieces') return 'pcs';
    if (u.startsWith('tray')) return 'trays';
    if (u.startsWith('litre')) return 'litres';
    if (u.startsWith('box')) return 'boxes';
    if (u == 'dozen') return 'dozen';
    if (u == 'k' || u.startsWith('kg') || u.startsWith('kilo')) return 'kgs';
    return u;
  }

  static ({double qty, String unit})? _tryParseQtyUnit(String text) {
    var clean = text.trim();
    if (clean.isEmpty) return null;

    // Pattern 1: "4 crates", "3 baqs", "15 bunches", "10 kgs"
    final m1 = RegExp(
      r'^([0-9OoIl.,]+)\s*([A-Za-z]+)$',
    ).firstMatch(clean);
    if (m1 != null) {
      final qty = parseOcrNumber(m1.group(1), treatTripleDotAsThousands: false);
      final unitRaw = m1.group(2)!.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      if (qty > 0 && _knownUnits.contains(unitRaw)) {
        return (qty: qty, unit: normalizeOcrUnit(unitRaw));
      }
    }

    // Pattern 2: single word number only ("5", "IO", "12")
    final numOnly = parseOcrNumber(clean, treatTripleDotAsThousands: false);
    if (numOnly > 0 && !clean.contains(RegExp(r'kes|ksh|@', caseSensitive: false))) {
      return (qty: numOnly, unit: '');
    }

    return null;
  }

  /// Parses 2D spatial rows into a structured wholesale docket payload matching
  /// Gemini's JSON shape cleanly.
  static Map<String, dynamic> parseBoxesToDocket(List<OcrTextBox> boxes) {
    final rows = reconstructDeskewedRows(boxes);
    var restaurantName = '';
    var invoiceNumber = '';
    var invoiceDate = '';
    var deliveryCost = 0.0;
    var subtotal = 0.0;
    var grandTotal = 0.0;
    final items = <Map<String, dynamic>>[];

    final invPattern = RegExp(
      r'(?:DKT|INV|TTG|TTM)[-#:\s]*[A-Z0-9-]+|(?:DOCKET|INVOICE)\s*(?:NO\.?|#)\s*:?\s*([A-Z0-9-]+)',
      caseSensitive: false,
    );
    final clientLabelPattern = RegExp(
      r'(?:client|customer|restaurant|hotel|deliver\s*to)\s*[:\-]\s*([A-Za-z0-9\s&\x27\.-]+?)(?:\s+date\b|$)',
      caseSensitive: false,
    );
    final datePattern = RegExp(
      r'\b(\d{4}-\d{2}-\d{2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b',
    );
    final deliveryPattern = RegExp(
      r'delivery(?:\s*(?:fee|cost))?\s*[:\-]?\s*(?:kes|ksh)?\s*([\d,.OoIl]+)',
      caseSensitive: false,
    );
    final subtotalPattern = RegExp(
      r'(?:sub\s*total|subtotal)\s*[:\-]?\s*(?:kes|ksh)?\s*([\d,.OoIl]+)',
      caseSensitive: false,
    );
    final grandTotalPattern = RegExp(
      r'grand\s*total\s*[:\-]?\s*(?:kes|ksh)?\s*([\d,.OoIl]+)',
      caseSensitive: false,
    );

    for (final row in rows) {
      final line = row.map((b) => b.text).join(' ').trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();

      if (invoiceNumber.isEmpty) {
        final invM = invPattern.firstMatch(line);
        if (invM != null) {
          final cand = (invM.group(1) ?? invM.group(0) ?? '').trim();
          if (cand.isNotEmpty && cand.length >= 3) {
            invoiceNumber = cand.replaceFirst(
              RegExp(r'^(?:DOCKET|INVOICE)\s*(?:NO\.?|#)\s*:?\s*', caseSensitive: false),
              '',
            ).trim();
          }
        }
      }

      if (invoiceDate.isEmpty) {
        final dm = datePattern.firstMatch(line);
        if (dm != null) {
          final norm = AppHelpers.normalizeAppDate(dm.group(1));
          if (norm.isNotEmpty) invoiceDate = norm;
        }
      }

      if (restaurantName.isEmpty) {
        final cm = clientLabelPattern.firstMatch(line);
        if (cm != null) {
          final name = cm.group(1)!.trim();
          if (name.isNotEmpty && !name.toLowerCase().contains('town treasure')) {
            restaurantName = name;
          }
        } else if (!lower.contains('town treasure') &&
            !lower.contains('town trfasure') &&
            (lower.contains('hotel') ||
                lower.contains('suites') ||
                lower.contains('resort') ||
                lower.contains('bistro') ||
                lower.contains('restaurant') ||
                lower.contains('lodge'))) {
          restaurantName = line;
        }
      }

      final delM = deliveryPattern.firstMatch(line);
      if (delM != null && lower.contains('delivery') && !lower.contains('docket')) {
        final v = parseOcrNumber(delM.group(1));
        if (v > 0) deliveryCost = v;
        continue;
      }

      final subM = subtotalPattern.firstMatch(line);
      if (subM != null) {
        final v = parseOcrNumber(subM.group(1));
        if (v > 0) subtotal = v;
        continue;
      }

      final gtM = grandTotalPattern.firstMatch(line);
      if (gtM != null) {
        final v = parseOcrNumber(gtM.group(1));
        if (v > 0) grandTotal = v;
        continue;
      }

      // Skip document chrome / table headers
      if (lower.contains('town treasure') ||
          lower.contains('town trfasure') ||
          lower.contains('delivery docket') ||
          lower.contains('commercial delivery') ||
          lower.contains('item description') ||
          (lower.contains('unit price') && lower.contains('total')) ||
          (lower.contains('qty') && lower.contains('total')) ||
          lower.startsWith('p.o.') ||
          lower.startsWith('po.') ||
          lower.startsWith('tel:') ||
          lower.startsWith('vat') ||
          lower.startsWith('address:') ||
          lower.startsWith('attention:') ||
          lower.startsWith('client:') ||
          lower.startsWith('date:') ||
          lower.startsWith('received') ||
          lower.startsWith('delivered by') ||
          lower.startsWith('signed')) {
        continue;
      }

      // Attempt cell-aware table row extraction from right to left
      final parsedItem = _extractItemFromRowCells(row);
      if (parsedItem != null) {
        items.add(parsedItem);
      }
    }

    if (subtotal == 0 && grandTotal > 0 && grandTotal >= deliveryCost) {
      subtotal = grandTotal - deliveryCost;
    }

    return {
      'restaurant_name': restaurantName,
      'invoice_number': invoiceNumber,
      'invoice_date': invoiceDate,
      'items': items,
      'delivery_cost': deliveryCost,
      'other_cost': 0.0,
      'subtotal': subtotal,
    };
  }

  static Map<String, dynamic>? _extractItemFromRowCells(List<OcrTextBox> row) {
    if (row.isEmpty) return null;

    // Expand space-separated cells lightly only when right-side cells have bundled values
    final tokens = row.map((b) => b.text.trim()).where((s) => s.isNotEmpty).toList();
    if (tokens.length < 2) {
      // Single wide line fallback
      final single = tokens.first;
      final m = RegExp(
        r'^(?:\d+[\.\)]\s*)?([A-Za-z][A-Za-z0-9\s\(\)\/&,-]{1,50}?)\s+(\d+(?:\.\d+)?)\s*([A-Za-z]+)\s*[@x]?\s*([\d,.]+)?\s*=?\s*([\d,.]+)?$',
        caseSensitive: false,
      ).firstMatch(single);
      if (m != null) {
        final desc = m.group(1)!.trim();
        final qty = parseOcrNumber(m.group(2), treatTripleDotAsThousands: false);
        final unit = normalizeOcrUnit(m.group(3) ?? 'kgs');
        final p = parseOcrNumber(m.group(4));
        final t = parseOcrNumber(m.group(5));
        if (desc.isNotEmpty && (p > 0 || t > 0)) {
          return {
            'desc': desc,
            'qty': qty > 0 ? qty : 1.0,
            'unit': unit,
            'price': p > 0 ? p : (qty > 0 && t > 0 ? t / qty : 0.0),
            'total': t > 0 ? t : qty * p,
          };
        }
      }
      return null;
    }

    // Walk backward from rightmost cell: Total -> Unit Price -> Unit / Qty -> Description
    var idx = tokens.length - 1;
    double? total;
    double? price;
    double? qty;
    String? unit;

    final lastVal = parseOcrNumber(tokens[idx]);
    if (lastVal <= 0) return null;
    total = lastVal;
    idx--;

    if (idx >= 1) {
      final secondLastVal = parseOcrNumber(tokens[idx]);
      if (secondLastVal > 0 && _tryParseQtyUnit(tokens[idx])?.unit.isEmpty != false) {
        // Confirm it isn't a unit-tagged quantity like "10 kgs"
        if (!RegExp(r'[A-Za-z]{2,}').hasMatch(tokens[idx].replaceAll(RegExp(r'(?:kes|ksh)', caseSensitive: false), ''))) {
          price = secondLastVal;
          idx--;
        }
      }
    }

    // Consume Unit and/or Qty cell(s) before description
    while (idx >= 1) {
      final cell = tokens[idx].trim();
      final qParsed = _tryParseQtyUnit(cell);
      if (qParsed != null) {
        qty ??= qParsed.qty;
        if (qParsed.unit.isNotEmpty && (unit == null || unit.isEmpty)) {
          unit = qParsed.unit;
        }
        idx--;
        continue;
      }
      final cleanWord = cell.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
      if (unit == null &&
          !RegExp(r'\d').hasMatch(cell) &&
          _knownUnits.contains(cleanWord)) {
        unit = normalizeOcrUnit(cleanWord);
        idx--;
        continue;
      }
      break;
    }

    final desc = tokens.sublist(0, idx + 1).join(' ').trim();
    if (desc.isEmpty ||
        RegExp(r'^[\d\W]+$').hasMatch(desc) ||
        desc.toLowerCase() == 'subtotal' ||
        desc.toLowerCase() == 'grand total') {
      return null;
    }

    final resolvedQty = qty ?? 1.0;
    var resolvedPrice = price ?? 0.0;
    var resolvedTotal = total;

    if (resolvedPrice == 0 && resolvedQty > 0 && resolvedTotal > 0) {
      resolvedPrice = resolvedTotal / resolvedQty;
    } else if (resolvedTotal == 0 && resolvedQty > 0 && resolvedPrice > 0) {
      resolvedTotal = resolvedQty * resolvedPrice;
    }

    return {
      'desc': desc,
      'qty': resolvedQty,
      'unit': unit != null && unit.isNotEmpty ? unit : 'kgs',
      'price': resolvedPrice,
      'total': resolvedTotal,
    };
  }

  /// Parses 2D spatial rows into produce price list categories & items.
  static Map<String, dynamic> parseBoxesToPriceList(List<OcrTextBox> boxes) {
    final rows = reconstructDeskewedRows(boxes);
    final items = <Map<String, dynamic>>[];
    final headerKeywords = RegExp(
      r'^(VEGETABLES|FRUITS|HERBS\s*&\s*SPICES|SPICES|DAIRY(?:\s*&\s*EGGS)?|CEREALS|MEAT|FISH|LEGUMES|ROOT\s*CROPS)$',
      caseSensitive: false,
    );

    for (final row in rows) {
      final line = row.map((b) => b.text).join(' ').trim();
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();

      if (lower.contains('town treasure') ||
          lower.contains('town trfasure') ||
          lower.contains('fresh produce supplies') ||
          lower.contains('produce price list') ||
          lower.contains('food supplies')) {
        continue;
      }

      if (headerKeywords.hasMatch(line)) {
        items.add({'isHeader': true, 'name': line.toUpperCase()});
        continue;
      }

      if (row.length >= 2) {
        final tokens = row.map((b) => b.text.trim()).where((s) => s.isNotEmpty).toList();
        final price = parseOcrNumber(tokens.last);
        if (price > 0) {
          var endIdx = tokens.length - 1;
          var unit = 'kgs';
          if (endIdx >= 2) {
            final cleanWord = tokens[endIdx - 1]
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z]'), '');
            if (_knownUnits.contains(cleanWord)) {
              unit = normalizeOcrUnit(cleanWord);
              endIdx--;
            }
          }
          final name = tokens.sublist(0, endIdx).join(' ').trim();
          if (name.isNotEmpty && !RegExp(r'^[\d\W]+$').hasMatch(name)) {
            items.add({
              'isHeader': false,
              'name': name,
              'unit': unit,
              'price': price,
            });
          }
        }
      }
    }

    return {
      'name': 'Scanned Price List',
      'subtitle': 'Food Supplies (Veg and Fruits)',
      'effectiveDate': AppHelpers.normalizeAppDate(DateTime.now()),
      'items': items,
    };
  }
}
