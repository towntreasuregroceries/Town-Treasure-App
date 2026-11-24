import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../../domain/models/models.dart';
import 'ocr_consensus_service.dart';

/// Unified representation of an invoice or staged docket for duplicate comparison.
class AuditRecord {
  const AuditRecord({
    required this.id,
    this.number = '',
    required this.restaurantName,
    required this.date,
    this.items = const [],
    this.totalSell = 0,
    this.notes = '',
    this.status = 'pending',
    this.clerkName = '',
    this.receiptPhoto,
    this.receiptPhotos = const [],
  });

  factory AuditRecord.fromDocket(StagingDocket docket) {
    return AuditRecord(
      id: docket.id,
      number: docket.generatedInvoiceNumber ?? '',
      restaurantName: docket.restaurantName,
      date: docket.invoiceDate,
      items: docket.itemsJson,
      totalSell: docket.totalSell,
      notes: docket.notes,
      status: docket.status,
      clerkName: docket.clerkName,
      receiptPhoto: docket.receiptPhoto,
      receiptPhotos: docket.receiptPhotos,
    );
  }

  factory AuditRecord.fromInvoice(Invoice invoice) {
    return AuditRecord(
      id: invoice.id,
      number: invoice.number,
      restaurantName: invoice.restaurantName,
      date: invoice.date,
      items: invoice.items,
      totalSell: invoice.totalSell,
      notes: invoice.notes,
      status: invoice.status,
    );
  }

  final String id;
  final String number;
  final String restaurantName;
  final String date;
  final List<InvoiceLineItem> items;
  final double totalSell;
  final String notes;
  final String status;
  final String clerkName;
  final String? receiptPhoto;
  final List<String> receiptPhotos;
}

class ItemMatchDetail {
  const ItemMatchDetail({
    required this.itemA,
    required this.itemB,
    required this.canonical,
    required this.qtyA,
    required this.qtyB,
    required this.score,
  });

  final String itemA;
  final String itemB;
  final String canonical;
  final String qtyA;
  final String qtyB;
  final double score;
}

class ItemListComparison {
  const ItemListComparison({
    required this.score,
    required this.matchingCount,
    this.totalA = 0,
    this.totalB = 0,
    this.matches = const [],
  });

  final double score;
  final int matchingCount;
  final int totalA;
  final int totalB;
  final List<ItemMatchDetail> matches;
}

class HeuristicScore {
  const HeuristicScore({
    required this.score,
    required this.hotelScore,
    required this.dateScore,
    required this.amountScore,
    required this.itemScore,
    this.itemCmp = const ItemListComparison(score: 0, matchingCount: 0),
    this.candTotal = 0,
    this.existTotal = 0,
  });

  final double score;
  final double hotelScore;
  final double dateScore;
  final double amountScore;
  final double itemScore;
  final ItemListComparison itemCmp;
  final double candTotal;
  final double existTotal;
}

class AuditResult {
  const AuditResult({
    required this.isDuplicate,
    required this.confidence,
    required this.determination,
    required this.explanation,
    required this.recommendedAction,
    this.matchedRecord,
    this.heuristicScore,
  });

  final bool isDuplicate;
  final int confidence;
  final String determination;
  final String explanation;
  final String recommendedAction;
  final AuditRecord? matchedRecord;
  final HeuristicScore? heuristicScore;
}

/// Smart Audit & Ledger Integrity Guard matching `TTGAudit` in `duplicate-detector.js`.
class DuplicateDetectorService {
  DuplicateDetectorService({
    http.Client? httpClient,
    String? geminiApiKey,
    this.apiKeyProvider,
  })  : _http = httpClient ?? http.Client(),
        _staticApiKey = geminiApiKey;

  final http.Client _http;
  final String? _staticApiKey;
  final String? Function()? apiKeyProvider;

  static const String _envGeminiKey = String.fromEnvironment('TTG_GEMINI_KEY');

  /// Alias mapping for common Kenyan produce & wholesale produce lines.
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

  static final RegExp _hotelStopwords = RegExp(
    r'\b(the|hotel|suites|resort|restaurant|club|inn|lodge|ltd|limited|kitchen|branch)\b',
    caseSensitive: false,
  );

  String getApiKey([String? overrideKey]) {
    if (overrideKey != null && overrideKey.trim().isNotEmpty) {
      return overrideKey.trim();
    }
    final provided = apiKeyProvider?.call();
    if (provided != null && provided.trim().isNotEmpty) {
      return provided.trim();
    }
    if (_staticApiKey != null && _staticApiKey.trim().isNotEmpty) {
      return _staticApiKey.trim();
    }
    if (_envGeminiKey.trim().isNotEmpty) {
      return _envGeminiKey.trim();
    }
    try {
      return utf8
          .decode(
            base64Decode(
              'QVEuQWI4Uk42SW01Smc5akhENVRMMDZxcE1vZXptdzdWTDRBa2tKYU1CUElfdDhscGY1YWc=',
            ),
          )
          .trim();
    } catch (_) {
      return '';
    }
  }

  /// Normalizes a restaurant / hotel name for matching (`normalizeHotel` in `duplicate-detector.js`).
  static String normalizeHotel(String? name) {
    if (name == null || name.isEmpty) return '';
    return name
        .toLowerCase()
        .replaceAll(_hotelStopwords, '')
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
  }

  /// Normalizes produce description to canonical form (`canonicalProduce` in `duplicate-detector.js`).
  static String canonicalProduce(String? desc) =>
      AppHelpers.canonicalProduce(desc);

  /// Alias for `canonicalProduce`.
  static String normalizeItemName(String? desc) => canonicalProduce(desc);

  static Map<String, ({String raw, double qty, String unit, double price})>
      _aggregateItems(List<InvoiceLineItem> items) {
    final grouped =
        <String, ({String raw, double qty, String unit, double price})>{};
    for (final i in items) {
      final canonical = canonicalProduce(i.desc);
      if (canonical.isEmpty) continue;
      final qty = i.qty <= 0 ? 1.0 : i.qty;
      final unit = i.unit.toLowerCase().trim().isEmpty
          ? 'kgs'
          : i.unit.toLowerCase().trim();
      final price = i.sellPrice > 0 ? i.sellPrice : i.buyPrice;
      final prev = grouped[canonical];
      if (prev == null) {
        grouped[canonical] = (
          raw: i.desc,
          qty: qty,
          unit: unit,
          price: price,
        );
      } else {
        final nextQty = prev.qty + qty;
        final nextPrice = nextQty > 0
            ? ((prev.qty * prev.price) + (qty * price)) / nextQty
            : max(prev.price, price);
        grouped[canonical] = (
          raw: prev.raw,
          qty: nextQty,
          unit: prev.unit,
          price: nextPrice,
        );
      }
    }
    return grouped;
  }

  /// Calculates Jaccard and unit similarity between two lists of produce items.
  static ItemListComparison compareItemLists(
    List<InvoiceLineItem> itemsA,
    List<InvoiceLineItem> itemsB,
  ) {
    if (itemsA.isEmpty || itemsB.isEmpty) {
      return const ItemListComparison(score: 0, matchingCount: 0);
    }

    final normA = _aggregateItems(itemsA);
    final normB = _aggregateItems(itemsB);

    if (normA.isEmpty || normB.isEmpty) {
      return const ItemListComparison(score: 0, matchingCount: 0);
    }

    final matches = <ItemMatchDetail>[];
    var matchScoreSum = 0.0;

    for (final entry in normA.entries) {
      final canonical = entry.key;
      final itemA = entry.value;
      final matchB = normB[canonical];
      if (matchB != null) {
        final maxQty = max(itemA.qty, matchB.qty);
        final qtyRatio =
            min(itemA.qty, matchB.qty) / (maxQty > 0 ? maxQty : 1.0);
        final priceMatch = (itemA.price > 0 && matchB.price > 0)
            ? min(itemA.price, matchB.price) / max(itemA.price, matchB.price)
            : 1.0;
        final itemScore = 0.5 + (0.3 * qtyRatio) + (0.2 * priceMatch);

        matches.add(
          ItemMatchDetail(
            itemA: itemA.raw,
            itemB: matchB.raw,
            canonical: canonical,
            qtyA: '${_fmtQty(itemA.qty)} ${itemA.unit}',
            qtyB: '${_fmtQty(matchB.qty)} ${matchB.unit}',
            score: itemScore,
          ),
        );
        matchScoreSum += itemScore;
      }
    }

    final unionCount = <String>{...normA.keys, ...normB.keys}.length;
    final jaccardScore = unionCount > 0 ? (matchScoreSum / unionCount) : 0.0;

    return ItemListComparison(
      score: min(1.0, jaccardScore),
      matchingCount: matches.length,
      totalA: normA.length,
      totalB: normB.length,
      matches: matches,
    );
  }

  /// Parses date string variants into a local calendar `DateTime`, or `null`.
  static DateTime? parseDateValue(Object? value) =>
      AppHelpers.parseAppDate(value);

  /// Tier 1 local heuristic match score between candidate and an existing record.
  static HeuristicScore calculateHeuristicScore(
    AuditRecord candidate,
    AuditRecord existing,
  ) {
    final candHotel = normalizeHotel(candidate.restaurantName);
    final existHotel = normalizeHotel(existing.restaurantName);

    // 1. Hotel Match (30%)
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
      return const HeuristicScore(
        score: 0,
        hotelScore: 0,
        dateScore: 0,
        amountScore: 0,
        itemScore: 0,
      );
    }

    // 2. Date Match (25%)
    var dateScore = 0.0;
    final d1 = parseDateValue(candidate.date);
    final d2 = parseDateValue(existing.date);
    if (d1 != null && d2 != null) {
      final diffDays = DateTime.utc(d1.year, d1.month, d1.day)
          .difference(DateTime.utc(d2.year, d2.month, d2.day))
          .inDays
          .abs();
      if (diffDays == 0) {
        dateScore = 1.0;
      } else if (diffDays <= 1) {
        dateScore = 0.7; // Late-night delivery vs morning billing
      } else if (diffDays <= 3) {
        dateScore = 0.3;
      }
    }

    // 3. Amount Match (25%)
    final candTotal = candidate.totalSell;
    final existTotal = existing.totalSell;
    var amountScore = 0.0;
    if (candTotal > 0 && existTotal > 0) {
      final diff = (candTotal - existTotal).abs();
      if (diff <= 2) {
        amountScore = 1.0;
      } else {
        final ratio = min(candTotal, existTotal) / max(candTotal, existTotal);
        if (ratio >= 0.98) {
          amountScore = 0.85;
        } else if (ratio >= 0.85) {
          amountScore = 0.5;
        }
      }
    }

    // 4. Line Items Overlap (20%)
    final itemCmp = compareItemLists(candidate.items, existing.items);
    final itemScore = itemCmp.score;

    // Weighted composite
    final composite = (hotelScore * 0.30) +
        (dateScore * 0.25) +
        (amountScore * 0.25) +
        (itemScore * 0.20);

    return HeuristicScore(
      score: min(1.0, (composite * 100).round() / 100.0),
      hotelScore: hotelScore,
      dateScore: dateScore,
      amountScore: amountScore,
      itemScore: itemScore,
      itemCmp: itemCmp,
      candTotal: candTotal,
      existTotal: existTotal,
    );
  }

  /// Same-day, near-identical value, and meaningful line-item overlap required for duplicate lock.
  static bool isHighConfidenceDuplicate(HeuristicScore scoreObj) {
    return scoreObj.hotelScore >= 0.85 &&
        scoreObj.dateScore == 1.0 &&
        scoreObj.itemCmp.matchingCount > 0 &&
        ((scoreObj.amountScore >= 0.85 && scoreObj.itemScore >= 0.55) ||
            (scoreObj.amountScore == 1.0 && scoreObj.itemScore >= 0.45));
  }

  /// Runs Smart Audit against a candidate docket/invoice and a pool of existing records.
  Future<AuditResult> auditSubmission(
    AuditRecord candidate,
    List<AuditRecord> pool, {
    bool useDeepAudit = true,
    String? excludeId,
    String? geminiApiKey,
  }) async {
    if (pool.isEmpty) {
      return const AuditResult(
        isDuplicate: false,
        confidence: 0,
        determination: 'DISTINCT_ORDER',
        explanation: 'No existing records to compare.',
        recommendedAction: 'ALLOW',
      );
    }

    final effectiveExcludeId = excludeId ?? candidate.id;
    final validPool = pool
        .where(
          (p) =>
              p.id.isNotEmpty &&
              p.id != effectiveExcludeId &&
              p.status != 'draft',
        )
        .toList();

    AuditRecord? bestMatch;
    var bestScoreObj = const HeuristicScore(
      score: 0,
      hotelScore: 0,
      dateScore: 0,
      amountScore: 0,
      itemScore: 0,
    );

    for (final record in validPool) {
      final scoreObj = calculateHeuristicScore(candidate, record);
      if (scoreObj.score > bestScoreObj.score) {
        bestScoreObj = scoreObj;
        bestMatch = record;
      }
    }

    if (bestMatch == null ||
        bestScoreObj.score < 0.40 ||
        bestScoreObj.hotelScore < 0.85 ||
        bestScoreObj.dateScore < 0.70 ||
        bestScoreObj.itemScore < 0.45) {
      return AuditResult(
        isDuplicate: false,
        confidence: (bestScoreObj.score * 100).round(),
        determination: 'DISTINCT_ORDER',
        explanation:
            'Verified distinct: No matching deliveries found for this client and date window.',
        recommendedAction: 'ALLOW',
      );
    }

    final apiKey = getApiKey(geminiApiKey);
    final canUseDeepAudit =
        useDeepAudit && apiKey.isNotEmpty && bestScoreObj.amountScore >= 0.50;

    if (canUseDeepAudit) {
      try {
        final deepResult = await _runBackgroundSemanticAudit(
          candidate,
          bestMatch,
          bestScoreObj,
          apiKey,
        );
        if (deepResult != null) return deepResult;
      } catch (_) {
        // Fall through to verified local heuristics
      }
    }

    final isDup = isHighConfidenceDuplicate(bestScoreObj);
    final determination = isDup
        ? 'EXACT_DUPLICATE'
        : (bestScoreObj.dateScore >= 0.7 && bestScoreObj.hotelScore >= 0.85
            ? 'SUPPLEMENTARY_ORDER'
            : 'DISTINCT_ORDER');
    final hotel =
        candidate.restaurantName.isNotEmpty ? candidate.restaurantName : 'Client';
    final date = candidate.date.isNotEmpty ? candidate.date : 'today';
    final total = NumberFormat('#,##0.##').format(bestScoreObj.candTotal);
    final numLabel = bestMatch.number.isNotEmpty
        ? bestMatch.number
        : bestMatch.id;

    return AuditResult(
      isDuplicate: isDup,
      confidence: (bestScoreObj.score * 100).round(),
      determination: determination,
      explanation: isDup
          ? 'Town Treasure Smart Audit detected a matching delivery for $hotel on $date (KES $total) recorded under #$numLabel.'
          : 'Potential order overlap detected for $hotel on $date. Please verify if this is an additional dispatch.',
      matchedRecord: bestMatch,
      heuristicScore: bestScoreObj,
      recommendedAction: isDup ? 'BLOCK_SUBMISSION' : 'FLAG_SUPPLEMENTARY',
    );
  }

  Future<AuditResult?> _runBackgroundSemanticAudit(
    AuditRecord candidate,
    AuditRecord matchedRecord,
    HeuristicScore scoreObj,
    String apiKey,
  ) async {
    final candItems = candidate.items
        .map((i) => '${_fmtQty(i.qty)} ${i.unit} of ${i.desc} @ KES ${i.sellPrice}')
        .join('\n');
    final existItems = matchedRecord.items
        .map((i) => '${_fmtQty(i.qty)} ${i.unit} of ${i.desc} @ KES ${i.sellPrice}')
        .join('\n');

    final matchedRef = matchedRecord.number.isNotEmpty
        ? matchedRecord.number
        : matchedRecord.id;

    final prompt = '''You are the automated Town Treasure Groceries Senior System Audit Engine.
Perform a strict, silent integrity audit comparing two delivery dockets to detect accidental duplicates, re-submissions, or legitimate supplementary dispatches.

DOCKET A (NEW CANDIDATE):
- Client / Destination: ${candidate.restaurantName.isNotEmpty ? candidate.restaurantName : 'Unknown'}
- Delivery Date: ${candidate.date.isNotEmpty ? candidate.date : 'Unknown'}
- Total Amount: KES ${scoreObj.candTotal}
- Items:
$candItems
- Notes: ${candidate.notes.isNotEmpty ? candidate.notes : 'None'}

DOCKET B (EXISTING IN SYSTEM #$matchedRef):
- Client / Destination: ${matchedRecord.restaurantName.isNotEmpty ? matchedRecord.restaurantName : 'Unknown'}
- Delivery Date: ${matchedRecord.date.isNotEmpty ? matchedRecord.date : 'Unknown'}
- Total Amount: KES ${scoreObj.existTotal}
- Items:
$existItems
- Notes: ${matchedRecord.notes.isNotEmpty ? matchedRecord.notes : 'None'}

INSTRUCTIONS:
1. Resolve Kenyan produce terminology (e.g. "Roma Tomatoes" == "Cooking Tomatoes"; "Hoho" == "Capsicum"; "Dhania" == "Coriander"; "Shangi" == "Potatoes").
2. Check unit and volume equivalences.
3. Determine if Docket A is:
   - "EXACT_DUPLICATE": The same physical produce order entered twice.
   - "SUPPLEMENTARY_ORDER": A legitimate second/emergency dispatch of the day for the same client.
   - "REVISION_OR_CORRECTION": An updated or corrected version of the earlier docket.
   - "DISTINCT_ORDER": Clearly unrelated distinct orders.
4. Provide a concise executive explanation (1-2 sentences) referencing client, date, and items.
5. Recommend the action: "BLOCK_SUBMISSION", "FLAG_SUPPLEMENTARY", or "ALLOW".

Return ONLY JSON matching:
{
  "is_duplicate": boolean,
  "confidence_percentage": integer,
  "determination": "EXACT_DUPLICATE" | "SUPPLEMENTARY_ORDER" | "REVISION_OR_CORRECTION" | "DISTINCT_ORDER",
  "explanation": "Executive explanation for Town Treasure audit",
  "recommended_action": "BLOCK_SUBMISSION" | "FLAG_SUPPLEMENTARY" | "ALLOW"
}''';

    final parts = <Map<String, dynamic>>[
      {'text': prompt},
    ];

    final candPhoto = candidate.receiptPhoto ??
        (candidate.receiptPhotos.isNotEmpty ? candidate.receiptPhotos.first : null);
    final existPhoto = matchedRecord.receiptPhoto ??
        (matchedRecord.receiptPhotos.isNotEmpty
            ? matchedRecord.receiptPhotos.first
            : null);

    final candDecoded = OcrConsensusService.decodeImageDataUrl(candPhoto);
    if (candDecoded != null) {
      parts.add({'text': 'Visual Photo of Docket A:'});
      parts.add({
        'inlineData': {
          'mimeType': candDecoded.mimeType,
          'data': base64Encode(candDecoded.bytes),
        },
      });
    }

    final existDecoded = OcrConsensusService.decodeImageDataUrl(existPhoto);
    if (existDecoded != null) {
      parts.add({'text': 'Visual Photo of Docket B:'});
      parts.add({
        'inlineData': {
          'mimeType': existDecoded.mimeType,
          'data': base64Encode(existDecoded.bytes),
        },
      });
    }

    final payload = {
      'contents': [
        {'parts': parts},
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'temperature': 0.1,
      },
    };

    const models = ['gemini-2.5-flash'];
    for (final model in models) {
      try {
        final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
        );
        final resp = await _http
            .post(
              uri,
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 8));
        if (resp.statusCode < 200 || resp.statusCode >= 300) continue;

        final data = jsonDecode(resp.body);
        final text = _extractGeminiText(data);
        if (text == null || text.trim().isEmpty) continue;

        final parsed = jsonDecode(text);
        if (parsed is! Map) continue;

        final isDup = parsed['is_duplicate'] == true;
        final conf = AppHelpers.parseInt(
          parsed['confidence_percentage'],
          (scoreObj.score * 100).round(),
        );
        return AuditResult(
          isDuplicate: isDup,
          confidence: conf,
          determination: (parsed['determination'] ??
                  (isDup ? 'EXACT_DUPLICATE' : 'SUPPLEMENTARY_ORDER'))
              .toString(),
          explanation: (parsed['explanation'] ??
                  'Town Treasure Smart Audit completed verification.')
              .toString(),
          matchedRecord: matchedRecord,
          heuristicScore: scoreObj,
          recommendedAction: (parsed['recommended_action'] ??
                  (isDup ? 'BLOCK_SUBMISSION' : 'FLAG_SUPPLEMENTARY'))
              .toString(),
        );
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  static String? _extractGeminiText(dynamic data) {
    if (data is! Map) return null;
    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    final first = candidates.first;
    if (first is! Map) return null;
    final content = first['content'];
    if (content is! Map) return null;
    final parts = content['parts'];
    if (parts is! List || parts.isEmpty) return null;
    final firstPart = parts.first;
    if (firstPart is! Map) return null;
    return firstPart['text']?.toString();
  }

  static String _fmtQty(double qty) {
    if (qty == qty.roundToDouble()) return qty.toInt().toString();
    return qty.toStringAsFixed(2);
  }
}
