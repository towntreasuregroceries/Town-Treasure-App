import 'dart:math' as math;

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
    'ky',
    'kys',
    'kq',
    'kqs',
    'k9',
    'k9s',
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

  /// Estimates dominant skew angle from wide boxes or baseline projection, rotates
  /// coordinates flat, and clusters text boxes into left-to-right visual table rows.
  static List<List<OcrTextBox>> reconstructDeskewedRows(List<OcrTextBox> boxes) {
    final valid = boxes.where((b) => b.text.trim().isNotEmpty).toList();
    if (valid.isEmpty) return const [];

    final heights = valid
        .map((b) => math.min(b.width, b.height))
        .where((h) => h > 0)
        .toList()
      ..sort();
    final medH = heights.isNotEmpty ? heights[heights.length ~/ 2] : 24.0;
    final baseTol = math.max(12.0, medH * 0.72);
    var rowThreshold = baseTol;

    final wideAngles = valid
        .where((b) => math.max(b.width, b.height) >= 40 && b.angle != 0)
        .map((b) => b.angle)
        .toList()
      ..sort();
    var medAngle = wideAngles.isNotEmpty
        ? wideAngles[wideAngles.length ~/ 2]
        : 0.0;

    // Only apply sparse pitch widening + baseline projection tilt when individual
    // boxes are near 0 deg AND horizontal clustering leaves >32% boxes isolated
    // (typical on wavy/tilted handwritten camera photos, never on crisp printed tables).
    if (medAngle.abs() < 1.5 && valid.length >= 6) {
      final zeroGroups = _clusterRowsAtAngle(valid, 0.0, baseTol);
      final zeroMultiCount = zeroGroups
          .where((g) => g.length >= 2)
          .fold<int>(0, (s, g) => s + g.length);

      if (zeroMultiCount < (valid.length * 0.82).ceil()) {
        double minX = double.infinity;
        double maxX = double.negativeInfinity;
        for (final b in valid) {
          if (b.centerX < minX) minX = b.centerX;
          if (b.centerX > maxX) maxX = b.centerX;
        }
        final spanX = maxX - minX;
        if (spanX >= 300) {
          final leftYs = valid
              .where((b) => b.centerX <= minX + spanX * 0.38)
              .map((b) => b.centerY)
              .toList()
            ..sort();
          final rowGaps = <double>[];
          for (var i = 0; i + 1 < leftYs.length; i++) {
            final gap = leftYs[i + 1] - leftYs[i];
            if (gap >= medH * 1.4) {
              rowGaps.add(gap);
            }
          }
          if (rowGaps.length >= 3) {
            rowGaps.sort();
            final medPitch = rowGaps[rowGaps.length ~/ 2];
            if (medPitch >= medH * 3.0) {
              rowThreshold = math.max(
                rowThreshold,
                math.min(medPitch * 0.35, medH * 2.0),
              );
            }
          }
          medAngle = _estimateBaselineTiltDeg(valid, tolY: rowThreshold);
        }
      }
    }

    final finalGroups = _clusterRowsAtAngle(valid, medAngle, rowThreshold);
    return finalGroups.map((group) {
      group.sort((a, b) => a.dx.compareTo(b.dx));
      return group.map((g) => g.box).toList();
    }).toList();
  }

  static List<List<_DeskewedBox>> _clusterRowsAtAngle(
    List<OcrTextBox> valid,
    double deg,
    double rowThreshold,
  ) {
    final rad = -deg * (math.pi / 180.0);
    final cosA = math.cos(rad);
    final sinA = math.sin(rad);

    final deskewed = valid.map((b) {
      final dx = b.centerX * cosA - b.centerY * sinA;
      final dy = b.centerX * sinA + b.centerY * cosA;
      return _DeskewedBox(box: b, dx: dx, dy: dy);
    }).toList()
      ..sort((a, b) => a.dy.compareTo(b.dy));

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
    return rowGroups;
  }

  static double _estimateBaselineTiltDeg(
    List<OcrTextBox> boxes, {
    required double tolY,
  }) {
    ({int multiCount, double spreadSum}) evalDeg(double deg) {
      final groups = _clusterRowsAtAngle(boxes, deg, tolY);
      var multiCount = 0;
      var spreadSum = 0.0;
      for (final g in groups) {
        if (g.length >= 2) {
          multiCount += g.length;
          spreadSum += g.last.dy - g.first.dy;
        }
      }
      return (multiCount: multiCount, spreadSum: spreadSum);
    }

    final zeroStats = evalDeg(0.0);
    var bestAngle = 0.0;
    var bestScore = zeroStats.multiCount * 100000.0 - zeroStats.spreadSum;

    for (var step = -24; step <= 24; step++) {
      if (step == 0) continue;
      final deg = step * 0.5;
      final stats = evalDeg(deg);
      if (stats.multiCount <= zeroStats.multiCount + 1) continue;
      final score =
          stats.multiCount * 100000.0 - stats.spreadSum - deg.abs() * 50.0;
      if (score > bestScore) {
        bestScore = score;
        bestAngle = deg;
      }
    }
    return bestAngle;
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
  /// (`1.OOO` -> `1000`, `IO` -> `10`, `3.200` / `36.800` -> `3200` / `36800`,
  /// `18.000,00` / `9.450.00` / `12.000 00` / `14 740 00` -> `18000`, `9450`, `12000`, `14740`).
  static double parseOcrNumber(String? raw, {bool treatTripleDotAsThousands = true}) {
    if (raw == null) return 0;
    var s = raw.trim();
    if (s.isEmpty) return 0;

    // Strip common currency & rate prefixes/suffixes
    s = s.replaceAll(
      RegExp(r'(?:kesi?|ksh|shs?\.?|@|=|/|-+$)', caseSensitive: false),
      '',
    ).trim();

    if (s.isEmpty) return 0;

    // Repair common OCR digit confusions only if token is predominantly numeric
    final repaired = s
        .replaceAll(RegExp(r'[Oo]'), '0')
        .replaceAll(RegExp(r'[Il|]'), '1')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (!RegExp(r'^[\d,.\s]+$').hasMatch(repaired)) {
      return 0;
    }

    // Rule A: Multi-group numbers with explicit 1-2 decimal digits at the end, e.g.:
    // "18.000,00", "9.450.00", "54.190.00", "12.000 00", "14 740 00", "1,400.00"
    final multiGroupDec = RegExp(
      r'^([\d,.\s]+?)[.,\s]+(\d{1,2})$',
    ).firstMatch(repaired);
    if (multiGroupDec != null) {
      final head = multiGroupDec.group(1)!;
      final dec = multiGroupDec.group(2)!;
      if (RegExp(r'[.,\s]').hasMatch(head)) {
        final whole = head.replaceAll(RegExp(r'[.,\s]'), '');
        return double.tryParse('$whole.$dec') ?? 0;
      }
    }

    // Rule B: Single comma decimal separator, e.g. "15,50"
    if (RegExp(r'^\d[\d\s]*,\d{1,2}$').hasMatch(repaired)) {
      s = repaired.replaceAll(' ', '').replaceAll(',', '.');
      return double.tryParse(s) ?? 0;
    }

    // Rule C: Standard integers, single decimals, or triple-dot thousands ("3.200")
    s = repaired.replaceAll(RegExp(r'[\s,]'), '');
    if (treatTripleDotAsThousands &&
        RegExp(r'^\d{1,3}(?:\.\d{3})+$').hasMatch(s)) {
      s = s.replaceAll('.', '');
    }

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
    if (u == 'k' ||
        u == 'ky' ||
        u == 'kys' ||
        u == 'kq' ||
        u == 'kqs' ||
        u == 'k9' ||
        u == 'k9s' ||
        u.startsWith('kg') ||
        u.startsWith('kilo')) {
      return 'kgs';
    }
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
      r'\b(?:DKT|INV|TTG|TTM)[-#:]\s*[A-Z0-9-]+|\b(?:DKT|INV|TTG|TTM)\s+\d[A-Z0-9-]*|(?:DOCKET|INVOICE|RECEIPT)\s*(?:NO\.?|#)\s*:?\s*([A-Z0-9-]+)',
      caseSensitive: false,
    );
    final clientLabelPattern = RegExp(
      r'(?:client|customer|restaurant|hotel|billed\s*to|bill\s*to|deliver\s*to)\s*[:\-]\s*([A-Za-z0-9\s&\x27\.-]+?)(?:\s+(?:order\s*)?date\b|$)',
      caseSensitive: false,
    );
    final datePattern = RegExp(
      r'\b(\d{4}-\d{2}-\d{2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\b',
    );
    final textDatePattern = RegExp(
      r'\b(\d{1,2})\s+(jan|feb|mar|apr|may|mav|jun|jul|aug|sep|oct|nov|dec)[a-z]*[,\s]+(\d{4})\b',
      caseSensitive: false,
    );
    const monthNums = <String, String>{
      'jan': '01',
      'feb': '02',
      'mar': '03',
      'apr': '04',
      'may': '05',
      'mav': '05',
      'jun': '06',
      'jul': '07',
      'aug': '08',
      'sep': '09',
      'oct': '10',
      'nov': '11',
      'dec': '12',
    };
    final deliveryPattern = RegExp(
      r'delivery(?:\s*(?:fee|cost))?\s*[:\-]?\s*(?:kes|ksh)?\s*([\d,.OoIl\s]+)',
      caseSensitive: false,
    );
    final subtotalPattern = RegExp(
      r'(?:sub\s*total|subtotal)\s*[:\-]?\s*(?:kes|ksh)?\s*([\d,.OoIl\s]+)',
      caseSensitive: false,
    );
    final grandTotalPattern = RegExp(
      r'grand\s*total\s*[:\-]?\s*(?:kes|ksh)?\s*([\d,.OoIl\s]+)',
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
              RegExp(r'^(?:DOCKET|INVOICE|RECEIPT)\s*(?:NO\.?|#)\s*:?\s*', caseSensitive: false),
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
        } else {
          final tm = textDatePattern.firstMatch(line);
          if (tm != null) {
            final day = tm.group(1)!.padLeft(2, '0');
            final mon = monthNums[tm.group(2)!.toLowerCase()];
            final year = tm.group(3)!;
            if (mon != null) {
              invoiceDate = '$year-$mon-$day';
            }
          }
        }
      }

      if (restaurantName.isEmpty && !lower.startsWith('thank')) {
        final cm = clientLabelPattern.firstMatch(line);
        if (cm != null) {
          final name = cm.group(1)!.trim();
          if (name.isNotEmpty && !name.toLowerCase().contains('town treasure')) {
            restaurantName = name;
          }
        } else {
          // Inspect individual row cells so split-column "FROM: Town Treasure | BILLED TO: Hotel" works cleanly
          for (final cell in row) {
            final cellTxt = cell.text.trim();
            final cellLower = cellTxt.toLowerCase();
            if (cellLower.contains('town treasure') ||
                cellLower.contains('town trfasure')) {
              continue;
            }
            if (cellLower.contains('hotel') ||
                cellLower.contains('suites') ||
                cellLower.contains('resort') ||
                cellLower.contains('bistro') ||
                cellLower.contains('restaurant') ||
                cellLower.contains('lodge') ||
                RegExp(r'\binn\b').hasMatch(cellLower)) {
              restaurantName = cellTxt;
              break;
            }
          }
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
          lower.contains('unit price') ||
          lower.contains('quantiy') ||
          (lower.contains('item') && lower.contains('qty') && lower.contains('total')) ||
          (lower.contains('item') && lower.contains('quantity')) ||
          (lower.contains('unit price') && lower.contains('total')) ||
          (lower.contains('qty') && lower.contains('total')) ||
          lower.startsWith('p.o.') ||
          lower.startsWith('po.') ||
          lower.startsWith('tel:') ||
          lower.startsWith('vat') ||
          lower.startsWith('address:') ||
          lower.startsWith('attention:') ||
          lower.startsWith('client:') ||
          lower.startsWith('billed to') ||
          lower.startsWith('from:') ||
          lower.startsWith('receipt no') ||
          lower.startsWith('order date') ||
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

  /// Strips leading row serial numbers (`01 `, `2. `, `#03 `) and embedded
  /// currency/rate annotations (`KSh 15.00`, `KES 30.00 / kgs`, `@120`) from an
  /// extracted produce description so invoice line names stay clean.
  static ({String desc, double? embeddedPrice, String? embeddedUnit})
      sanitizeProduceDescription(String rawDesc) {
    var clean = rawDesc.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) {
      return (desc: '', embeddedPrice: null, embeddedUnit: null);
    }

    double? embeddedPrice;
    String? embeddedUnit;

    // 1. Strip trailing currency/rate tags (e.g. "KSh 15.00", "KES 350.00 / kgs", "@120")
    final trailingRatePattern = RegExp(
      r'\s*(?:@|\b(?:ksh|kes|shs?)\b\.?)\s*([\d,]+(?:\.\d{1,2})?)(?:\s*/\s*([A-Za-z]+))?\s*$',
      caseSensitive: false,
    );
    for (var pass = 0; pass < 2; pass++) {
      final m = trailingRatePattern.firstMatch(clean);
      if (m == null) break;
      final parsedVal = parseOcrNumber(
        m.group(1),
        treatTripleDotAsThousands: false,
      );
      if (parsedVal > 0 && embeddedPrice == null) {
        embeddedPrice = parsedVal;
      }
      final rawUnit = (m.group(2) ?? '').trim();
      if (rawUnit.isNotEmpty &&
          _knownUnits.contains(rawUnit.toLowerCase()) &&
          embeddedUnit == null) {
        embeddedUnit = normalizeOcrUnit(rawUnit);
      }
      clean = clean.substring(0, m.start).trim();
    }

    // Also strip dangling currency markers left without digits at the end.
    clean = clean
        .replaceFirst(
          RegExp(r'\s+\b(?:ksh|kes|shs?)\.?$', caseSensitive: false),
          '',
        )
        .trim();

    // 2. Strip leading row serial numbers (e.g. "01 Dhania", "02 Parsley", "1. Cabbage")
    final serialMatch = RegExp(
      r'^(?:#\s*)?(\d{1,3})([.)])?\s+([A-Za-z][A-Za-z0-9\s\(\)\/&,-]*)$',
    ).firstMatch(clean);
    if (serialMatch != null) {
      final hasPunct = serialMatch.group(2) != null;
      final remainder = serialMatch.group(3)!.trim();
      final firstWord = remainder
          .split(RegExp(r'\s+'))
          .first
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z]'), '');
      if (hasPunct ||
          (!_knownUnits.contains(firstWord) && firstWord.length >= 2)) {
        clean = remainder;
      }
    }

    return (
      desc: clean.replaceFirst(RegExp(r'[\s/\-:]+$'), '').trim(),
      embeddedPrice: embeddedPrice,
      embeddedUnit: embeddedUnit,
    );
  }

  static Map<String, dynamic>? _extractItemFromRowCells(List<OcrTextBox> row) {
    if (row.isEmpty) return null;

    // Expand space-separated cells lightly only when right-side cells have bundled values
    final tokens = row.map((b) => b.text.trim()).where((s) => s.isNotEmpty).toList();
    if (tokens.length < 2) {
      // Single wide line fallback
      final single = tokens.first;
      final m = RegExp(
        r'^(?:\d+[\.\)]\s*)?([A-Za-z0-9][A-Za-z0-9\s\(\)\/&.,-]{1,65}?)\s+(\d+(?:\.\d+)?)\s*([A-Za-z]+)\s*[@x]?\s*([\d,.]+)?\s*=?\s*([\d,.]+)?$',
        caseSensitive: false,
      ).firstMatch(single);
      if (m != null) {
        final cleaned = sanitizeProduceDescription(m.group(1)!);
        final desc = cleaned.desc;
        final qty = parseOcrNumber(m.group(2), treatTripleDotAsThousands: false);
        final unit = normalizeOcrUnit(m.group(3) ?? cleaned.embeddedUnit ?? 'kgs');
        final parsedP = parseOcrNumber(m.group(4));
        final p = parsedP > 0 ? parsedP : (cleaned.embeddedPrice ?? 0.0);
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

    // Skip an explicit leftmost row index column (e.g. "01", "2.") when followed by text
    var startIdx = 0;
    while (tokens.length - startIdx >= 3 &&
        RegExp(r'^(?:#\s*)?0?\d{1,2}[.)]?$').hasMatch(tokens[startIdx])) {
      startIdx++;
    }

    // Walk backward from rightmost cell: Total -> Unit Price / Qty -> Description
    // OR handle 3-column "Item | Unit Price | Qty+Unit" sheets with no Total column.
    var idx = tokens.length - 1;
    double total = 0;
    double? price;
    double? qty;
    String? unit;

    final lastVal = parseOcrNumber(tokens[idx]);
    if (lastVal > 0) {
      total = lastVal;
      idx--;
    } else {
      final rightQty = _tryParseQtyUnit(tokens[idx]);
      final fuzzyUnitSuffix = RegExp(
        r'^[A-Za-z0-9]{1,5}\s*(kgs?|ky|kq|kilograms?|bags?|crates?|bunches?|bundles?|pcs|pieces?|trays?|litres?|dozen)$',
        caseSensitive: false,
      ).firstMatch(tokens[idx].trim());

      if (rightQty != null &&
          rightQty.unit.isNotEmpty &&
          idx - 1 >= startIdx + 1) {
        final leftPrice = parseOcrNumber(tokens[idx - 1]);
        if (leftPrice > 0) {
          qty = rightQty.qty;
          unit = rightQty.unit;
          price = leftPrice;
          total = qty * price;
          idx -= 2;
        } else {
          return null;
        }
      } else if (fuzzyUnitSuffix != null && idx - 1 >= startIdx + 1) {
        final leftPrice = parseOcrNumber(tokens[idx - 1]);
        if (leftPrice > 0) {
          qty = 1.0;
          unit = normalizeOcrUnit(fuzzyUnitSuffix.group(1)!);
          price = leftPrice;
          total = leftPrice;
          idx -= 2;
        } else {
          return null;
        }
      } else {
        return null;
      }
    }

    if (price == null && idx >= startIdx + 1) {
      final secondLastVal = parseOcrNumber(tokens[idx]);
      if (secondLastVal > 0 && _tryParseQtyUnit(tokens[idx])?.unit.isEmpty != false) {
        // Confirm it isn't a unit-tagged quantity like "10 kgs"
        if (!RegExp(r'[A-Za-z]{2,}').hasMatch(
            tokens[idx].replaceAll(RegExp(r'(?:kes|ksh)', caseSensitive: false), ''))) {
          price = secondLastVal;
          idx--;
        }
      }
    }

    // Consume Unit, Qty, and Rate cell(s) before description
    while (idx >= startIdx + 1) {
      final cell = tokens[idx].trim();
      final qParsed = _tryParseQtyUnit(cell);
      if (qParsed != null) {
        if (qty == null) {
          qty = qParsed.qty;
          if (qParsed.unit.isNotEmpty && (unit == null || unit.isEmpty)) {
            unit = qParsed.unit;
          }
          idx--;
          continue;
        }
        // A bare numeric cell left of Qty is a Unit Price (Rate before Qty layout)
        if (price == null && qParsed.unit.isEmpty && qParsed.qty > 0) {
          price = qParsed.qty;
          idx--;
          continue;
        }
      }

      // Check rate/price cells with currency or "/unit", e.g. "KSh 15.00" or "KSh 15.00 / kgs"
      final rateMatch = RegExp(
        r'^(?:@|\b(?:ksh|kes|shs?)\b\.?)?\s*([\d,OoIl]+(?:\.\d{1,2})?)(?:\s*/\s*([A-Za-z]+))?$',
        caseSensitive: false,
      ).firstMatch(cell);
      if (rateMatch != null &&
          (cell.contains(RegExp(r'kes|ksh|shs|@|/', caseSensitive: false)))) {
        final rateVal = parseOcrNumber(
          rateMatch.group(1),
          treatTripleDotAsThousands: false,
        );
        if (rateVal > 0 && price == null) {
          price = rateVal;
          final rUnit = (rateMatch.group(2) ?? '').trim();
          if (rUnit.isNotEmpty &&
              _knownUnits.contains(rUnit.toLowerCase()) &&
              (unit == null || unit.isEmpty)) {
            unit = normalizeOcrUnit(rUnit);
          }
          idx--;
          continue;
        }
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

    final rawJoinedDesc = tokens.sublist(startIdx, idx + 1).join(' ').trim();
    final cleaned = sanitizeProduceDescription(rawJoinedDesc);
    final desc = cleaned.desc;
    if (desc.isEmpty ||
        RegExp(r'^[\d\W]+$').hasMatch(desc) ||
        desc.toLowerCase() == 'subtotal' ||
        desc.toLowerCase() == 'grand total') {
      return null;
    }
    price ??= cleaned.embeddedPrice;
    if (unit == null || unit.isEmpty) {
      unit = cleaned.embeddedUnit;
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
